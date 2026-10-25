// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Receptor de flash loans (ERC-3156).
interface IERC3156FlashBorrower {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32);
}

/// @notice Oráculo de precio colateral→activo (8 decimales).
interface IOracle {
    function price() external view returns (uint256);
}

/// @title LendingPool — Préstamos sobre-colateralizados con liquidaciones y flash loans
/// @notice Mercado de un activo prestable (p. ej. DAI) contra un colateral (p. ej. WETH).
///   - **Prestamistas** depositan DAI y reciben *shares* que se revalorizan con los intereses.
///   - **Prestatarios** depositan WETH y piden DAI hasta el **LTV 75%**.
///   - Si el **health factor** < 1 (deuda > colateral·80%), cualquiera **liquida** hasta el
///     50% de la deuda y recibe colateral con 5% de bonus.
///   - **Flash loans** ERC-3156 del DAI ocioso con 0,09% de fee para los prestamistas.
///   - Tasa de interés por **curva con kink** según utilización.
/// @dev La contabilidad usa `cash` interno, NO `balanceOf(this)`. Así un flash loan (que saca
///      tokens temporalmente) o una donación directa no alteran el precio de las shares.
contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ------------------------------------------------------------------
    // Parámetros
    // ------------------------------------------------------------------
    uint256 public constant WAD = 1e18;
    uint256 public constant LTV = 0.75e18; // máximo para pedir prestado
    uint256 public constant LIQ_THRESHOLD = 0.80e18; // HF se calcula con este
    uint256 public constant LIQ_BONUS = 0.05e18;
    uint256 public constant CLOSE_FACTOR = 0.5e18;
    uint256 public constant RESERVE_FACTOR = 0.10e18; // 10% del interés al protocolo
    uint256 public constant FLASH_FEE_BPS = 9; // 0,09%
    // Curva de tasas (anuales, WAD)
    uint256 public constant BASE_RATE = 0.02e18;
    uint256 public constant SLOPE1 = 0.10e18;
    uint256 public constant SLOPE2 = 1.00e18;
    uint256 public constant KINK = 0.80e18;
    uint256 private constant YEAR = 365 days;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    IERC20 public immutable asset; // prestable
    IERC20 public immutable collateralToken;
    IOracle public immutable oracle;
    address public immutable reserveRecipient;

    // ------------------------------------------------------------------
    // Estado
    // ------------------------------------------------------------------
    uint256 public cash; // activo disponible contabilizado
    uint256 public totalBorrows; // deuda total con intereses (al último accrue)
    uint256 public reserves; // parte del protocolo
    uint256 public borrowIndex = WAD; // acumulador de interés
    uint256 public lastAccrual;
    uint256 public totalShares;
    bool public flashActive;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public collateralOf;

    struct BorrowSnapshot {
        uint256 principal; // deuda al momento del snapshot
        uint256 index; // borrowIndex en ese momento
    }

    mapping(address => BorrowSnapshot) internal borrows;

    // ------------------------------------------------------------------
    // Eventos / errores
    // ------------------------------------------------------------------
    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Withdraw(address indexed user, uint256 assets, uint256 shares);
    event CollateralAdded(address indexed user, uint256 amount);
    event CollateralRemoved(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed payer, address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed user, uint256 repaid, uint256 seized);
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);

    error ZeroAmount();
    error InsufficientCash();
    error Unhealthy();
    error Healthy();
    error TooMuchRepay();
    error FlashActive();
    error BadToken();
    error CallbackFailed();
    error InsufficientShares();

    constructor(IERC20 _asset, IERC20 _collateral, IOracle _oracle, address _reserveRecipient) {
        asset = _asset;
        collateralToken = _collateral;
        oracle = _oracle;
        reserveRecipient = _reserveRecipient;
        lastAccrual = block.timestamp;
    }

    /// @dev Bloquea operaciones que cambian el precio de las shares o la liquidez mientras
    ///      hay un flash loan en curso (defensa en profundidad).
    modifier noFlash() {
        if (flashActive) revert FlashActive();
        _;
    }

    // ------------------------------------------------------------------
    // Intereses
    // ------------------------------------------------------------------

    /// @notice Utilización = borrows / (cash + borrows − reserves).
    function utilization() public view returns (uint256) {
        uint256 supplied = cash + totalBorrows - reserves;
        return supplied == 0 ? 0 : totalBorrows.mulDiv(WAD, supplied);
    }

    /// @notice Tasa anual de préstamo según la curva con kink.
    function borrowRate() public view returns (uint256) {
        uint256 u = utilization();
        if (u <= KINK) return BASE_RATE + SLOPE1.mulDiv(u, KINK);
        return BASE_RATE + SLOPE1 + SLOPE2.mulDiv(u - KINK, WAD - KINK);
    }

    /// @notice Devenga interés desde el último accrue (interés simple por intervalo, compuesto entre llamadas).
    function accrue() public {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return;
        lastAccrual = block.timestamp;
        if (totalBorrows == 0) return;
        uint256 factor = borrowRate() * dt / YEAR; // WAD
        uint256 interest = totalBorrows.mulDiv(factor, WAD);
        totalBorrows += interest;
        reserves += interest.mulDiv(RESERVE_FACTOR, WAD);
        borrowIndex += borrowIndex.mulDiv(factor, WAD);
    }

    // ------------------------------------------------------------------
    // Prestamistas
    // ------------------------------------------------------------------

    /// @notice Activos totales de los prestamistas.
    function totalAssets() public view returns (uint256) {
        return cash + totalBorrows - reserves;
    }

    /// @notice Deposita `amount` del activo y recibe shares.
    /// @dev Shares "virtuales" (+1 / +1e3) para mitigar el ataque de inflación del primer depositante.
    function deposit(uint256 amount) external nonReentrant noFlash returns (uint256 s) {
        accrue();
        if (amount == 0) revert ZeroAmount();
        s = amount.mulDiv(totalShares + 1e3, totalAssets() + 1);
        shares[msg.sender] += s;
        totalShares += s;
        cash += amount;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount, s);
    }

    /// @notice Quema shares y retira el activo (redondeo a favor del pool).
    function withdraw(uint256 s) external nonReentrant noFlash returns (uint256 amount) {
        accrue();
        if (s == 0) revert ZeroAmount();
        if (s > shares[msg.sender]) revert InsufficientShares();
        amount = s.mulDiv(totalAssets() + 1, totalShares + 1e3);
        if (amount > cash) revert InsufficientCash();
        shares[msg.sender] -= s;
        totalShares -= s;
        cash -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount, s);
    }

    function balanceOfUnderlying(address user) external view returns (uint256) {
        return shares[user].mulDiv(totalAssets() + 1, totalShares + 1e3);
    }

    // ------------------------------------------------------------------
    // Prestatarios
    // ------------------------------------------------------------------

    function addCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        collateralOf[msg.sender] += amount;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralAdded(msg.sender, amount);
    }

    function removeCollateral(uint256 amount) external nonReentrant noFlash {
        accrue();
        collateralOf[msg.sender] -= amount; // revierte por underflow si no alcanza
        if (debtOf(msg.sender) > maxBorrow(msg.sender)) revert Unhealthy();
        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralRemoved(msg.sender, amount);
    }

    /// @notice Pide prestado hasta el LTV.
    function borrow(uint256 amount) external nonReentrant noFlash {
        accrue();
        if (amount == 0) revert ZeroAmount();
        if (amount > cash) revert InsufficientCash();
        uint256 newDebt = debtOf(msg.sender) + amount;
        if (newDebt > maxBorrow(msg.sender)) revert Unhealthy();
        borrows[msg.sender] = BorrowSnapshot(newDebt, borrowIndex);
        totalBorrows += amount;
        cash -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    /// @notice Repaga la deuda de `user` (cualquiera puede repagar por otro).
    function repay(address user, uint256 amount) external nonReentrant returns (uint256 paid) {
        accrue();
        paid = _repay(msg.sender, user, amount);
    }

    function _repay(address payer, address user, uint256 amount) internal returns (uint256) {
        uint256 debt = debtOf(user);
        if (amount > debt) amount = debt;
        if (amount == 0) revert ZeroAmount();
        borrows[user] = BorrowSnapshot(debt - amount, borrowIndex);
        // por redondeo, totalBorrows puede quedar 1 wei por debajo de la suma de deudas
        totalBorrows = amount > totalBorrows ? 0 : totalBorrows - amount;
        cash += amount;
        asset.safeTransferFrom(payer, address(this), amount);
        emit Repay(payer, user, amount);
        return amount;
    }

    // ------------------------------------------------------------------
    // Liquidación
    // ------------------------------------------------------------------

    /// @notice Health factor (WAD). < 1e18 => liquidable.
    function healthFactor(address user) public view returns (uint256) {
        uint256 debt = debtOf(user);
        if (debt == 0) return type(uint256).max;
        return collateralValue(user).mulDiv(LIQ_THRESHOLD, debt);
    }

    /// @notice Liquida hasta el 50% de la deuda de `user`.
    /// @dev Permitido durante un flash loan (es el caso de uso típico de los bots).
    function liquidate(address user, uint256 repayAmount) external nonReentrant returns (uint256 seized) {
        accrue();
        if (healthFactor(user) >= WAD) revert Healthy();
        uint256 debt = debtOf(user);
        if (repayAmount > debt.mulDiv(CLOSE_FACTOR, WAD)) revert TooMuchRepay();
        // colateral = repago / precio × (1 + bonus)
        seized = repayAmount.mulDiv(1e8, oracle.price()).mulDiv(WAD + LIQ_BONUS, WAD);
        if (seized > collateralOf[user]) seized = collateralOf[user];
        collateralOf[user] -= seized;
        _repay(msg.sender, user, repayAmount);
        collateralToken.safeTransfer(msg.sender, seized);
        emit Liquidate(msg.sender, user, repayAmount, seized);
    }

    // ------------------------------------------------------------------
    // Flash loans (ERC-3156)
    // ------------------------------------------------------------------

    function maxFlashLoan(address token) external view returns (uint256) {
        return token == address(asset) ? cash : 0;
    }

    function flashFee(address token, uint256 amount) public view returns (uint256) {
        if (token != address(asset)) revert BadToken();
        return amount.mulDiv(FLASH_FEE_BPS, 10_000, Math.Rounding.Ceil);
    }

    /// @notice Presta `amount` dentro de la misma tx; el receptor debe aprobar amount+fee.
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        noFlash
        returns (bool)
    {
        if (amount > cash) revert InsufficientCash();
        uint256 fee = flashFee(token, amount);
        flashActive = true;
        asset.safeTransfer(address(receiver), amount);
        if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) != CALLBACK_SUCCESS) revert CallbackFailed();
        // cobro explícito (no confiamos en balanceOf)
        asset.safeTransferFrom(address(receiver), address(this), amount + fee);
        flashActive = false;
        cash += fee; // la fee queda para los prestamistas
        emit FlashLoan(address(receiver), amount, fee);
        return true;
    }

    // ------------------------------------------------------------------
    // Vistas y reservas
    // ------------------------------------------------------------------

    /// @notice Deuda actual = principal × indexActual / indexSnapshot.
    function debtOf(address user) public view returns (uint256) {
        BorrowSnapshot memory b = borrows[user];
        if (b.principal == 0) return 0;
        return b.principal.mulDiv(borrowIndex, b.index, Math.Rounding.Ceil);
    }

    function collateralValue(address user) public view returns (uint256) {
        return collateralOf[user].mulDiv(oracle.price(), 1e8);
    }

    function maxBorrow(address user) public view returns (uint256) {
        return collateralValue(user).mulDiv(LTV, WAD);
    }

    /// @notice Envía las reservas al destinatario del protocolo.
    function withdrawReserves() external nonReentrant noFlash {
        accrue();
        uint256 r = reserves;
        if (r > cash) r = cash;
        reserves -= r;
        cash -= r;
        asset.safeTransfer(reserveRecipient, r);
    }
}
