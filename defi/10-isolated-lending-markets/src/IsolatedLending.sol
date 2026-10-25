// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracle, IIrm} from "./Interfaces.sol";

/// @title IsolatedLending — mercados de préstamo AISLADOS y sin permiso (estilo Silo / Morpho Blue)
/// @notice Cada mercado es un par (colateral, token prestado) con su propio oráculo, modelo
///         de tasa y LLTV. El riesgo de un mercado NO contagia a los demás: si un colateral
///         colapsa, la deuda incobrable se absorbe solo entre los prestamistas de ese mercado.
///         Cualquiera puede crear un mercado (sin gobernanza), eligiendo entre los IRM y
///         LLTV habilitados por el owner.
/// @dev Contrato singleton: todos los mercados viven aquí (ahorra gas de deploy y permite
///      composición). Usa "shares" con desplazamiento virtual para evitar ataques de inflación.
contract IsolatedLending is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_SCALE = 1e36;
    /// @notice Desplazamiento virtual de shares/activos (defensa contra inflación de shares).
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;
    /// @notice Incentivo de liquidación máximo (15 %).
    uint256 public constant MAX_LIF = 1.15e18;
    /// @notice Cursor de LIF: LIF = min(MAX, 1 / (1 − 0,3·(1 − LLTV))).
    uint256 public constant LIF_CURSOR = 0.3e18;

    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv; // LTV de liquidación, WAD
    }

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint64 lastUpdate;
    }

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    mapping(bytes32 => Market) public market;
    mapping(bytes32 => MarketParams) public idToParams;
    mapping(bytes32 => mapping(address => Position)) public position;
    mapping(address => bool) public isIrmEnabled;
    mapping(uint256 => bool) public isLltvEnabled;

    event MarketCreated(bytes32 indexed id, MarketParams params);
    event Supply(bytes32 indexed id, address indexed onBehalf, uint256 assets, uint256 shares);
    event Withdraw(bytes32 indexed id, address indexed user, uint256 assets, uint256 shares);
    event SupplyCollateral(bytes32 indexed id, address indexed onBehalf, uint256 assets);
    event WithdrawCollateral(bytes32 indexed id, address indexed user, uint256 assets);
    event Borrow(bytes32 indexed id, address indexed user, uint256 assets, uint256 shares);
    event Repay(bytes32 indexed id, address indexed onBehalf, uint256 assets, uint256 shares);
    event Liquidate(bytes32 indexed id, address indexed borrower, uint256 repaid, uint256 seized, uint256 badDebt);

    error MarketExists();
    error MarketNotCreated();
    error NotEnabled();
    error Unhealthy();
    error Healthy();
    error InsufficientLiquidity();
    error ZeroAmount();

    constructor() Ownable(msg.sender) {}

    // ------------------------------------------------------------------
    // Gobernanza mínima: qué IRM y LLTV pueden usarse
    // ------------------------------------------------------------------

    function enableIrm(address irm) external onlyOwner {
        isIrmEnabled[irm] = true;
    }

    function enableLltv(uint256 lltv) external onlyOwner {
        require(lltv < WAD, "lltv");
        isLltvEnabled[lltv] = true;
    }

    /// @notice Identificador determinístico del mercado.
    function id(MarketParams memory p) public pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    /// @notice Crea un mercado (sin permiso).
    function createMarket(MarketParams memory p) external returns (bytes32 mid) {
        if (!isIrmEnabled[p.irm] || !isLltvEnabled[p.lltv]) revert NotEnabled();
        mid = id(p);
        if (market[mid].lastUpdate != 0) revert MarketExists();
        market[mid].lastUpdate = uint64(block.timestamp);
        idToParams[mid] = p;
        emit MarketCreated(mid, p);
    }

    // ------------------------------------------------------------------
    // Conversiones con shares virtuales
    // ------------------------------------------------------------------

    /// @dev assets → shares. Con VIRTUAL_SHARES, inflar el precio de la share requiere donar
    ///      1e6 veces más que lo que se le puede robar al siguiente depositante.
    function _toShares(uint256 assets, uint256 totalAssets, uint256 totalShares, Math.Rounding r)
        internal
        pure
        returns (uint256)
    {
        return assets.mulDiv(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS, r);
    }

    function _toAssets(uint256 shares, uint256 totalAssets, uint256 totalShares, Math.Rounding r)
        internal
        pure
        returns (uint256)
    {
        return shares.mulDiv(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, r);
    }

    // ------------------------------------------------------------------
    // Intereses
    // ------------------------------------------------------------------

    /// @notice Acumula intereses de un mercado.
    /// @dev Interés compuesto aproximado con Taylor: e^(rt) − 1 ≈ x + x²/2 + x³/6.
    function accrueInterest(MarketParams memory p) public {
        bytes32 mid = id(p);
        Market storage m = market[mid];
        if (m.lastUpdate == 0) revert MarketNotCreated();
        uint256 dt = block.timestamp - m.lastUpdate;
        if (dt == 0) return;
        m.lastUpdate = uint64(block.timestamp);
        if (m.totalBorrowAssets == 0) return;
        uint256 rate = IIrm(p.irm).borrowRate(m.totalSupplyAssets, m.totalBorrowAssets);
        uint256 x = rate * dt;
        uint256 x2 = x.mulDiv(x, 2 * WAD);
        uint256 x3 = x2.mulDiv(x, 3 * WAD);
        uint256 interest = uint256(m.totalBorrowAssets).mulDiv(x + x2 + x3, WAD);
        m.totalBorrowAssets += uint128(interest);
        m.totalSupplyAssets += uint128(interest); // todo el interés va a los prestamistas
    }

    // ------------------------------------------------------------------
    // Prestamistas
    // ------------------------------------------------------------------

    function supply(MarketParams memory p, uint256 assets, address onBehalf) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        accrueInterest(p);
        bytes32 mid = id(p);
        Market storage m = market[mid];
        shares = _toShares(assets, m.totalSupplyAssets, m.totalSupplyShares, Math.Rounding.Floor);
        position[mid][onBehalf].supplyShares += shares;
        m.totalSupplyShares += uint128(shares);
        m.totalSupplyAssets += uint128(assets);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        emit Supply(mid, onBehalf, assets, shares);
    }

    /// @notice Retira por shares (shares = max => todas).
    function withdraw(MarketParams memory p, uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        accrueInterest(p);
        bytes32 mid = id(p);
        Market storage m = market[mid];
        Position storage pos = position[mid][msg.sender];
        if (shares == type(uint256).max) shares = pos.supplyShares;
        if (shares == 0) revert ZeroAmount();
        assets = _toAssets(shares, m.totalSupplyAssets, m.totalSupplyShares, Math.Rounding.Floor);
        pos.supplyShares -= shares;
        m.totalSupplyShares -= uint128(shares);
        m.totalSupplyAssets -= uint128(assets);
        if (m.totalBorrowAssets > m.totalSupplyAssets) revert InsufficientLiquidity();
        IERC20(p.loanToken).safeTransfer(receiver, assets);
        emit Withdraw(mid, msg.sender, assets, shares);
    }

    // ------------------------------------------------------------------
    // Prestatarios
    // ------------------------------------------------------------------

    function supplyCollateral(MarketParams memory p, uint256 assets, address onBehalf) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        bytes32 mid = id(p);
        if (market[mid].lastUpdate == 0) revert MarketNotCreated();
        position[mid][onBehalf].collateral += uint128(assets);
        IERC20(p.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        emit SupplyCollateral(mid, onBehalf, assets);
    }

    function withdrawCollateral(MarketParams memory p, uint256 assets, address receiver) external nonReentrant {
        if (assets == 0) revert ZeroAmount();
        accrueInterest(p);
        bytes32 mid = id(p);
        position[mid][msg.sender].collateral -= uint128(assets);
        if (!_isHealthy(p, mid, msg.sender)) revert Unhealthy();
        IERC20(p.collateralToken).safeTransfer(receiver, assets);
        emit WithdrawCollateral(mid, msg.sender, assets);
    }

    function borrow(MarketParams memory p, uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        accrueInterest(p);
        bytes32 mid = id(p);
        Market storage m = market[mid];
        shares = _toShares(assets, m.totalBorrowAssets, m.totalBorrowShares, Math.Rounding.Ceil);
        position[mid][msg.sender].borrowShares += uint128(shares);
        m.totalBorrowShares += uint128(shares);
        m.totalBorrowAssets += uint128(assets);
        if (m.totalBorrowAssets > m.totalSupplyAssets) revert InsufficientLiquidity();
        if (!_isHealthy(p, mid, msg.sender)) revert Unhealthy();
        IERC20(p.loanToken).safeTransfer(receiver, assets);
        emit Borrow(mid, msg.sender, assets, shares);
    }

    /// @notice Repaga por shares (max = todas las del deudor).
    function repay(MarketParams memory p, uint256 shares, address onBehalf) external nonReentrant returns (uint256 assets) {
        accrueInterest(p);
        bytes32 mid = id(p);
        Market storage m = market[mid];
        Position storage pos = position[mid][onBehalf];
        if (shares == type(uint256).max) shares = pos.borrowShares;
        if (shares == 0) revert ZeroAmount();
        assets = _toAssets(shares, m.totalBorrowAssets, m.totalBorrowShares, Math.Rounding.Ceil);
        pos.borrowShares -= uint128(shares);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = uint128(_zeroFloorSub(m.totalBorrowAssets, assets));
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        emit Repay(mid, onBehalf, assets, shares);
    }

    // ------------------------------------------------------------------
    // Liquidaciones
    // ------------------------------------------------------------------

    /// @notice Incentivo de liquidación del mercado: cuanto menor el LLTV, mayor el colchón.
    function liquidationIncentive(uint256 lltv) public pure returns (uint256) {
        uint256 lif = WAD.mulDiv(WAD, WAD - LIF_CURSOR.mulDiv(WAD - lltv, WAD));
        return lif < MAX_LIF ? lif : MAX_LIF;
    }

    /// @notice Liquida tomando `seized` colateral. Repaga deuda = seized · precio / LIF.
    /// @dev Si tras la liquidación el deudor queda sin colateral pero con deuda, esa deuda
    ///      incobrable se resta de `totalSupplyAssets` **de este mercado** (aislamiento).
    function liquidate(MarketParams memory p, address borrower, uint256 seized)
        external
        nonReentrant
        returns (uint256 repaidAssets, uint256 badDebt)
    {
        if (seized == 0) revert ZeroAmount();
        accrueInterest(p);
        bytes32 mid = id(p);
        if (_isHealthy(p, mid, borrower)) revert Healthy();
        Market storage m = market[mid];
        Position storage pos = position[mid][borrower];
        uint256 price = IOracle(p.oracle).price();
        uint256 lif = liquidationIncentive(p.lltv);

        if (seized > pos.collateral) seized = pos.collateral;
        repaidAssets = seized.mulDiv(price, ORACLE_SCALE, Math.Rounding.Ceil).mulDiv(WAD, lif, Math.Rounding.Ceil);
        uint256 repaidShares = _toShares(repaidAssets, m.totalBorrowAssets, m.totalBorrowShares, Math.Rounding.Floor);
        if (repaidShares > pos.borrowShares) {
            repaidShares = pos.borrowShares;
            repaidAssets = _toAssets(repaidShares, m.totalBorrowAssets, m.totalBorrowShares, Math.Rounding.Ceil);
        }
        pos.borrowShares -= uint128(repaidShares);
        m.totalBorrowShares -= uint128(repaidShares);
        m.totalBorrowAssets = uint128(_zeroFloorSub(m.totalBorrowAssets, repaidAssets));
        pos.collateral -= uint128(seized);

        // Socialización de deuda incobrable SOLO dentro del mercado
        if (pos.collateral == 0 && pos.borrowShares > 0) {
            uint256 badShares = pos.borrowShares;
            badDebt = _toAssets(badShares, m.totalBorrowAssets, m.totalBorrowShares, Math.Rounding.Ceil);
            if (badDebt > m.totalBorrowAssets) badDebt = m.totalBorrowAssets;
            m.totalBorrowAssets -= uint128(badDebt);
            m.totalSupplyAssets = uint128(_zeroFloorSub(m.totalSupplyAssets, badDebt));
            m.totalBorrowShares -= uint128(badShares);
            pos.borrowShares = 0;
        }

        IERC20(p.collateralToken).safeTransfer(msg.sender, seized);
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);
        emit Liquidate(mid, borrower, repaidAssets, seized, badDebt);
    }

    // ------------------------------------------------------------------
    // Lecturas
    // ------------------------------------------------------------------

    function _isHealthy(MarketParams memory p, bytes32 mid, address user) internal view returns (bool) {
        Position storage pos = position[mid][user];
        if (pos.borrowShares == 0) return true;
        Market storage m = market[mid];
        uint256 debt = _toAssets(pos.borrowShares, m.totalBorrowAssets, m.totalBorrowShares, Math.Rounding.Ceil);
        uint256 maxBorrow = uint256(pos.collateral).mulDiv(IOracle(p.oracle).price(), ORACLE_SCALE).mulDiv(p.lltv, WAD);
        return maxBorrow >= debt;
    }

    function isHealthy(MarketParams memory p, address user) external view returns (bool) {
        return _isHealthy(p, id(p), user);
    }

    function supplyAssetsOf(MarketParams memory p, address user) external view returns (uint256) {
        bytes32 mid = id(p);
        Market storage m = market[mid];
        return _toAssets(position[mid][user].supplyShares, m.totalSupplyAssets, m.totalSupplyShares, Math.Rounding.Floor);
    }

    function borrowAssetsOf(MarketParams memory p, address user) external view returns (uint256) {
        bytes32 mid = id(p);
        Market storage m = market[mid];
        return _toAssets(position[mid][user].borrowShares, m.totalBorrowAssets, m.totalBorrowShares, Math.Rounding.Ceil);
    }

    function _zeroFloorSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
