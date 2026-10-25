// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {JumpRateModel} from "./JumpRateModel.sol";
import {PriceOracle} from "./PriceOracle.sol";

/// @title LendingPool — protocolo de préstamos multi-activo con pool compartido (estilo Aave/Compound)
/// @notice Los usuarios:
///         - depositan activos que ganan interés y sirven como colateral;
///         - piden prestado contra ese colateral, pagando interés variable según la utilización;
///         - si su health factor cae por debajo de 1, cualquiera puede liquidarlos con un bonus.
/// @dev Contabilidad por índices (RAY = 1e27). Cada usuario guarda saldos "escalados"; el saldo
///      real es `escalado · índice`. Acumular intereses solo cambia el índice: O(1) para
///      cualquier cantidad de usuarios.
///      Redondeo: siempre a favor del protocolo (depósitos y repagos hacia abajo; préstamos y
///      retiros hacia arriba).
contract LendingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    /// @notice Máximo de la deuda de un activo que puede liquidarse en una llamada.
    uint256 public constant CLOSE_FACTOR = 0.5e18;

    struct Market {
        bool listed;
        uint8 decimals;
        uint64 lastAccrual;
        uint256 ltv; // WAD: cuánto se puede pedir prestado por unidad de colateral (ej. 0,75)
        uint256 liquidationThreshold; // WAD: umbral para el health factor (ej. 0,80)
        uint256 liquidationBonus; // WAD: premio del liquidador (ej. 0,05 = 5 %)
        uint256 reserveFactor; // WAD: parte del interés que va a la tesorería
        JumpRateModel rateModel;
        uint256 supplyIndex; // RAY
        uint256 borrowIndex; // RAY
        uint256 totalScaledSupply;
        uint256 totalScaledBorrow;
        uint256 cash; // liquidez contabilizada (no usamos balanceOf: evita donaciones)
    }

    PriceOracle public oracle;
    address public treasury;

    mapping(address => Market) public markets;
    address[] public assetList;
    mapping(address => mapping(address => uint256)) public scaledSupplyOf; // asset => user
    mapping(address => mapping(address => uint256)) public scaledBorrowOf;

    event MarketListed(address indexed asset);
    event Deposit(address indexed asset, address indexed user, uint256 amount);
    event Withdraw(address indexed asset, address indexed user, uint256 amount);
    event Borrow(address indexed asset, address indexed user, uint256 amount);
    event Repay(address indexed asset, address indexed payer, address indexed user, uint256 amount);
    event Liquidation(
        address indexed liquidator,
        address indexed user,
        address debtAsset,
        address collateralAsset,
        uint256 repaid,
        uint256 seized
    );

    error NotListed();
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error HealthyPosition();
    error TooMuchRepay();
    error BadParams();

    constructor(PriceOracle _oracle, address _treasury) Ownable(msg.sender) {
        oracle = _oracle;
        treasury = _treasury;
    }

    // ------------------------------------------------------------------
    // Administración
    // ------------------------------------------------------------------

    /// @notice Lista un activo con sus parámetros de riesgo.
    function listMarket(
        address asset,
        uint256 ltv,
        uint256 liqThreshold,
        uint256 liqBonus,
        uint256 reserveFactor,
        JumpRateModel model
    ) external onlyOwner {
        if (markets[asset].listed) revert BadParams();
        // ltv < umbral: hay un colchón entre "no puedo pedir más" y "me liquidan".
        // umbral·(1+bonus) < 1: el bonus no puede dejar la posición más insolvente.
        if (ltv > liqThreshold || liqThreshold >= WAD || (liqThreshold * (WAD + liqBonus)) / WAD >= WAD) {
            revert BadParams();
        }
        if (reserveFactor > 0.5e18) revert BadParams();
        markets[asset] = Market({
            listed: true,
            decimals: IERC20Metadata(asset).decimals(),
            lastAccrual: uint64(block.timestamp),
            ltv: ltv,
            liquidationThreshold: liqThreshold,
            liquidationBonus: liqBonus,
            reserveFactor: reserveFactor,
            rateModel: model,
            supplyIndex: RAY,
            borrowIndex: RAY,
            totalScaledSupply: 0,
            totalScaledBorrow: 0,
            cash: 0
        });
        assetList.push(asset);
        emit MarketListed(asset);
    }

    // ------------------------------------------------------------------
    // Intereses
    // ------------------------------------------------------------------

    /// @notice Acumula intereses de un mercado hasta el bloque actual.
    /// @dev interés = deuda · tasa · Δt (interés simple por intervalo, compuesto entre
    ///      intervalos). Los depositantes reciben `interés·(1−rf)` vía supplyIndex; la tesorería
    ///      recibe `interés·rf` como saldo de depósito escalado.
    function accrue(address asset) public {
        Market storage m = markets[asset];
        if (!m.listed) revert NotListed();
        uint256 dt = block.timestamp - m.lastAccrual;
        if (dt == 0) return;
        m.lastAccrual = uint64(block.timestamp);
        uint256 debt = Math.mulDiv(m.totalScaledBorrow, m.borrowIndex, RAY);
        if (debt == 0) return;
        uint256 u = m.rateModel.utilization(m.cash, debt);
        uint256 factor = m.rateModel.borrowRatePerSecond(u) * dt; // RAY
        uint256 interest = Math.mulDiv(debt, factor, RAY);
        m.borrowIndex += Math.mulDiv(m.borrowIndex, factor, RAY);

        uint256 supplied = Math.mulDiv(m.totalScaledSupply, m.supplyIndex, RAY);
        if (supplied == 0) return;
        uint256 reserve = Math.mulDiv(interest, m.reserveFactor, WAD);
        m.supplyIndex += Math.mulDiv(m.supplyIndex, interest - reserve, supplied);
        uint256 treasuryScaled = Math.mulDiv(reserve, RAY, m.supplyIndex);
        scaledSupplyOf[asset][treasury] += treasuryScaled;
        m.totalScaledSupply += treasuryScaled;
    }

    function _accrueAll() internal {
        for (uint256 i; i < assetList.length; i++) {
            accrue(assetList[i]);
        }
    }

    // ------------------------------------------------------------------
    // Operaciones de usuario
    // ------------------------------------------------------------------

    /// @notice Deposita `amount` del activo (gana interés y cuenta como colateral).
    function deposit(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrue(asset);
        Market storage m = markets[asset];
        uint256 scaled = Math.mulDiv(amount, RAY, m.supplyIndex); // hacia abajo
        if (scaled == 0) revert ZeroAmount();
        scaledSupplyOf[asset][msg.sender] += scaled;
        m.totalScaledSupply += scaled;
        m.cash += amount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(asset, msg.sender, amount);
    }

    /// @notice Retira `amount` (type(uint256).max = todo). Debe quedar sano.
    function withdraw(address asset, uint256 amount) external nonReentrant returns (uint256) {
        _accrueAll();
        Market storage m = markets[asset];
        uint256 bal = supplyBalance(asset, msg.sender);
        if (amount == type(uint256).max) amount = bal;
        if (amount == 0 || amount > bal) revert ZeroAmount();
        if (amount > m.cash) revert InsufficientLiquidity();
        uint256 scaled = Math.mulDiv(amount, RAY, m.supplyIndex, Math.Rounding.Ceil); // hacia arriba
        if (scaled > scaledSupplyOf[asset][msg.sender]) scaled = scaledSupplyOf[asset][msg.sender];
        scaledSupplyOf[asset][msg.sender] -= scaled;
        m.totalScaledSupply -= scaled;
        m.cash -= amount;
        // Chequeo de solvencia DESPUÉS de actualizar el estado
        if (healthFactor(msg.sender) < WAD) revert InsufficientCollateral();
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdraw(asset, msg.sender, amount);
        return amount;
    }

    /// @notice Pide prestado `amount`. Requiere colateral·LTV ≥ deuda total.
    function borrow(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueAll();
        Market storage m = markets[asset];
        if (amount > m.cash) revert InsufficientLiquidity();
        uint256 scaled = Math.mulDiv(amount, RAY, m.borrowIndex, Math.Rounding.Ceil);
        scaledBorrowOf[asset][msg.sender] += scaled;
        m.totalScaledBorrow += scaled;
        m.cash -= amount;
        (, uint256 debtUsd, uint256 borrowLimit,) = accountData(msg.sender);
        if (debtUsd > borrowLimit) revert InsufficientCollateral();
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Borrow(asset, msg.sender, amount);
    }

    /// @notice Repaga deuda de `onBehalf` (max = toda la deuda).
    function repay(address asset, uint256 amount, address onBehalf) external nonReentrant returns (uint256) {
        accrue(asset);
        amount = _repay(asset, msg.sender, onBehalf, amount);
        return amount;
    }

    function _repay(address asset, address payer, address user, uint256 amount) internal returns (uint256) {
        Market storage m = markets[asset];
        uint256 debt = borrowBalance(asset, user);
        if (amount > debt) amount = debt;
        if (amount == 0) revert ZeroAmount();
        uint256 scaled = amount == debt
            ? scaledBorrowOf[asset][user]
            : Math.mulDiv(amount, RAY, m.borrowIndex); // hacia abajo: se descuenta menos deuda
        scaledBorrowOf[asset][user] -= scaled;
        m.totalScaledBorrow -= scaled;
        m.cash += amount;
        IERC20(asset).safeTransferFrom(payer, address(this), amount);
        emit Repay(asset, payer, user, amount);
        return amount;
    }

    /// @notice Liquida una posición con health factor < 1.
    /// @dev El liquidador paga hasta el 50 % de la deuda en `debtAsset` y recibe colateral
    ///      equivalente + bonus. Si el colateral no alcanza, se ajusta el repago a lo que cubre.
    /// @return repaid Deuda efectivamente repagada.
    /// @return seized Colateral entregado al liquidador.
    function liquidate(address debtAsset, address collateralAsset, address user, uint256 repayAmount)
        external
        nonReentrant
        returns (uint256 repaid, uint256 seized)
    {
        _accrueAll();
        if (healthFactor(user) >= WAD) revert HealthyPosition();
        uint256 debt = borrowBalance(debtAsset, user);
        uint256 maxRepay = Math.mulDiv(debt, CLOSE_FACTOR, WAD);
        if (repayAmount > maxRepay) revert TooMuchRepay();

        Market storage c = markets[collateralAsset];
        uint256 pDebt = oracle.getPrice(debtAsset);
        uint256 pColl = oracle.getPrice(collateralAsset);
        // colateral = repago · pDeuda/pColateral · (1 + bonus), ajustando decimales
        seized = _seizeAmount(repayAmount, debtAsset, collateralAsset, pDebt, pColl, c.liquidationBonus);
        uint256 available = supplyBalance(collateralAsset, user);
        if (seized > available) {
            // Reducimos el repago proporcionalmente para no tomar más colateral del que hay.
            repayAmount = Math.mulDiv(repayAmount, available, seized);
            seized = available;
        }
        if (seized > c.cash) revert InsufficientLiquidity();
        repaid = _repay(debtAsset, msg.sender, user, repayAmount);

        uint256 scaled = Math.mulDiv(seized, RAY, c.supplyIndex, Math.Rounding.Ceil);
        if (scaled > scaledSupplyOf[collateralAsset][user]) scaled = scaledSupplyOf[collateralAsset][user];
        scaledSupplyOf[collateralAsset][user] -= scaled;
        c.totalScaledSupply -= scaled;
        c.cash -= seized;
        IERC20(collateralAsset).safeTransfer(msg.sender, seized);
        emit Liquidation(msg.sender, user, debtAsset, collateralAsset, repaid, seized);
    }

    function _seizeAmount(uint256 repayAmt, address debtAsset, address collAsset, uint256 pDebt, uint256 pColl, uint256 bonus)
        internal
        view
        returns (uint256)
    {
        uint256 usd = Math.mulDiv(repayAmt, pDebt, 10 ** markets[debtAsset].decimals);
        uint256 usdWithBonus = Math.mulDiv(usd, WAD + bonus, WAD);
        return Math.mulDiv(usdWithBonus, 10 ** markets[collAsset].decimals, pColl);
    }

    // ------------------------------------------------------------------
    // Lecturas
    // ------------------------------------------------------------------

    /// @notice Depósito actual (con intereses acumulados hasta el último accrue).
    function supplyBalance(address asset, address user) public view returns (uint256) {
        return Math.mulDiv(scaledSupplyOf[asset][user], markets[asset].supplyIndex, RAY);
    }

    /// @notice Deuda actual (redondeada hacia arriba).
    function borrowBalance(address asset, address user) public view returns (uint256) {
        return Math.mulDiv(scaledBorrowOf[asset][user], markets[asset].borrowIndex, RAY, Math.Rounding.Ceil);
    }

    /// @notice Resumen de la cuenta en USD (WAD).
    /// @return collateralUsd Valor del colateral.
    /// @return debtUsd Valor de la deuda.
    /// @return borrowLimitUsd Σ colateral·LTV.
    /// @return liquidationUsd Σ colateral·umbral de liquidación.
    function accountData(address user)
        public
        view
        returns (uint256 collateralUsd, uint256 debtUsd, uint256 borrowLimitUsd, uint256 liquidationUsd)
    {
        for (uint256 i; i < assetList.length; i++) {
            address a = assetList[i];
            Market storage m = markets[a];
            uint256 s = scaledSupplyOf[a][user];
            uint256 b = scaledBorrowOf[a][user];
            if (s == 0 && b == 0) continue;
            uint256 p = oracle.getPrice(a);
            uint256 unit = 10 ** m.decimals;
            if (s > 0) {
                uint256 v = Math.mulDiv(supplyBalance(a, user), p, unit);
                collateralUsd += v;
                borrowLimitUsd += Math.mulDiv(v, m.ltv, WAD);
                liquidationUsd += Math.mulDiv(v, m.liquidationThreshold, WAD);
            }
            if (b > 0) debtUsd += Math.mulDiv(borrowBalance(a, user), p, unit, Math.Rounding.Ceil);
        }
    }

    /// @notice Health factor (WAD). < 1e18 => liquidable. Sin deuda => infinito.
    function healthFactor(address user) public view returns (uint256) {
        (, uint256 debt,, uint256 liq) = accountData(user);
        if (debt == 0) return type(uint256).max;
        return Math.mulDiv(liq, WAD, debt);
    }

    /// @notice Utilización y tasas actuales de un mercado.
    function marketRates(address asset) external view returns (uint256 util, uint256 borrowApr, uint256 supplyApr) {
        Market storage m = markets[asset];
        uint256 debt = Math.mulDiv(m.totalScaledBorrow, m.borrowIndex, RAY);
        util = m.rateModel.utilization(m.cash, debt);
        borrowApr = m.rateModel.borrowRate(util);
        supplyApr = m.rateModel.supplyRate(util, m.reserveFactor);
    }

    function assetsCount() external view returns (uint256) {
        return assetList.length;
    }
}
