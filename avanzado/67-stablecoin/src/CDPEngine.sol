// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Stablecoin} from "./Stablecoin.sol";

/// @notice Interfaz mínima de un price feed estilo Chainlink.
interface IPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title CDPEngine — Motor de deuda colateralizada (estilo MakerDAO simplificado)
/// @notice Los usuarios depositan colateral (WETH) y acuñan USD100 contra él.
///         - **Ratio mínimo (MCR)** 150% para acuñar o retirar.
///         - **Umbral de liquidación (LT)** 130%: por debajo, cualquiera puede liquidar.
///         - **Tasa de estabilidad dinámica**: interés anual que sube cuando USD100 cotiza
///           bajo $1 (encarece la deuda, incentiva recomprar y repagar) y baja cuando
///           cotiza sobre $1 (abarata acuñar y aumenta la oferta).
///         - Interés compuesto por acumulador `rateAcc` (RAY); la deuda se guarda "normalizada".
///         - Las comisiones se acuñan al `treasury` (superávit del protocolo).
/// @dev Unidades: colateral 18 dec, USD100 18 dec, precios 8 dec, tasas en RAY (1e27).
contract CDPEngine is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Parámetros
    // ------------------------------------------------------------------
    uint256 public constant RAY = 1e27;
    uint256 public constant BPS = 10_000;
    uint256 public constant MCR_BPS = 15_000; // 150%
    uint256 public constant LT_BPS = 13_000; // 130%
    uint256 public constant LIQ_BONUS_BPS = 1_000; // 10% de premio al liquidador
    uint256 public constant CLOSE_FACTOR_BPS = 5_000; // máx 50% de la deuda por liquidación
    uint256 public constant DUST = 100e18; // deuda mínima por vault (evita vaults no rentables de liquidar)
    uint256 public constant MAX_STALENESS = 1 hours;

    /// @notice Tasa base anual (bps) cuando el peg está perfecto.
    uint256 public constant BASE_RATE_BPS = 200; // 2%
    /// @notice bps anuales extra por cada 1% de desvío bajo el peg.
    uint256 public constant SENSITIVITY_BPS_PER_PCT = 200;
    uint256 public constant MAX_RATE_BPS = 5_000; // 50% techo
    uint256 private constant YEAR = 365 days;

    IERC20 public immutable collateral;
    Stablecoin public immutable stable;
    IPriceFeed public immutable collateralFeed; // WETH/USD
    IPriceFeed public immutable pegFeed; // USD100/USD (precio de mercado)
    address public treasury;
    uint256 public debtCeiling;

    // ------------------------------------------------------------------
    // Estado
    // ------------------------------------------------------------------
    struct Vault {
        uint256 collateral; // cantidad de colateral
        uint256 normDebt; // deuda / rateAcc (no cambia con el tiempo)
    }

    mapping(address => Vault) public vaults;
    uint256 public totalNormDebt;
    /// @notice Acumulador de interés (RAY). deuda real = normDebt * rateAcc / RAY.
    uint256 public rateAcc = RAY;
    /// @notice Tasa por segundo vigente (RAY).
    uint256 public ratePerSecond;
    uint256 public annualRateBps;
    uint256 public lastDrip;
    /// @notice Deuda incobrable acumulada (colateral insuficiente en liquidaciones).
    uint256 public badDebt;

    // ------------------------------------------------------------------
    // Eventos / errores
    // ------------------------------------------------------------------
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Minted(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 repaid, uint256 seized);
    event RateUpdated(uint256 annualBps, uint256 pegPrice);
    event Dripped(uint256 fees, uint256 newRateAcc);

    error ZeroAmount();
    error BelowMCR();
    error NotLiquidatable();
    error CeilingExceeded();
    error StalePrice();
    error BadPrice();
    error ExceedsCloseFactor();
    error DustVault();
    error InsufficientCollateral();

    constructor(IERC20 _collateral, IPriceFeed _collFeed, IPriceFeed _pegFeed, address _treasury, uint256 _ceiling)
        Ownable(msg.sender)
    {
        collateral = _collateral;
        collateralFeed = _collFeed;
        pegFeed = _pegFeed;
        treasury = _treasury;
        debtCeiling = _ceiling;
        stable = new Stablecoin(address(this));
        lastDrip = block.timestamp;
        _setRate(BASE_RATE_BPS, 1e8);
    }

    // ------------------------------------------------------------------
    // Tasa dinámica e intereses
    // ------------------------------------------------------------------

    /// @notice Acumula interés desde `lastDrip` y acuña las comisiones al treasury.
    /// @dev Compuesto discreto: rateAcc *= (1 + r·dt). Cada drip compone; con drips frecuentes
    ///      se aproxima al compuesto continuo. Lo llama cada función que toca deuda.
    function drip() public {
        uint256 dt = block.timestamp - lastDrip;
        if (dt == 0) return;
        lastDrip = block.timestamp;
        uint256 oldAcc = rateAcc;
        uint256 newAcc = oldAcc + (oldAcc * ratePerSecond * dt) / RAY;
        rateAcc = newAcc;
        uint256 fees = (totalNormDebt * (newAcc - oldAcc)) / RAY;
        if (fees > 0) stable.mint(treasury, fees);
        emit Dripped(fees, newAcc);
    }

    /// @notice Recalcula la tasa según el precio de mercado de USD100 (permisionless).
    /// @dev Política: rate = BASE + SENS·(desvío% bajo $1), en [0, MAX]. Sobre $1 la tasa
    ///      baja en la misma proporción. Primero se hace `drip` con la tasa vieja.
    function updateRate() external {
        drip();
        uint256 peg = _price(pegFeed);
        uint256 rate;
        if (peg < 1e8) {
            // desvío en "centésimas de punto porcentual": (1e8 - peg) / 1e4 = bps de desvío
            uint256 devBps = (1e8 - peg) / 1e4;
            rate = BASE_RATE_BPS + (devBps * SENSITIVITY_BPS_PER_PCT) / 100;
            if (rate > MAX_RATE_BPS) rate = MAX_RATE_BPS;
        } else {
            uint256 devBps = (peg - 1e8) / 1e4;
            uint256 cut = (devBps * SENSITIVITY_BPS_PER_PCT) / 100;
            rate = cut >= BASE_RATE_BPS ? 0 : BASE_RATE_BPS - cut;
        }
        _setRate(rate, peg);
    }

    function _setRate(uint256 bps, uint256 peg) internal {
        annualRateBps = bps;
        // bps -> fracción RAY: bps * 1e27 / 1e4 = bps * 1e23; luego por segundo
        ratePerSecond = (bps * 1e23) / YEAR;
        emit RateUpdated(bps, peg);
    }

    // ------------------------------------------------------------------
    // Acciones del usuario
    // ------------------------------------------------------------------

    /// @notice Deposita colateral.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        vaults[msg.sender].collateral += amount;
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Retira colateral si el vault queda sobre el MCR.
    function withdraw(uint256 amount) external nonReentrant {
        drip();
        Vault storage v = vaults[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > v.collateral) revert InsufficientCollateral();
        v.collateral -= amount;
        if (!_isAbove(v, MCR_BPS)) revert BelowMCR();
        collateral.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Acuña USD100 contra el colateral.
    function mint(uint256 amount) external nonReentrant {
        drip();
        if (amount == 0) revert ZeroAmount();
        Vault storage v = vaults[msg.sender];
        // redondeo hacia ARRIBA de la deuda normalizada (a favor del protocolo)
        uint256 norm = _divUp(amount * RAY, rateAcc);
        v.normDebt += norm;
        totalNormDebt += norm;
        if (totalDebt() > debtCeiling) revert CeilingExceeded();
        if (debtOf(msg.sender) < DUST) revert DustVault();
        if (!_isAbove(v, MCR_BPS)) revert BelowMCR();
        stable.mint(msg.sender, amount);
        emit Minted(msg.sender, amount);
    }

    /// @notice Repaga deuda (quema USD100 del llamador). `amount = type(uint256).max` repaga todo.
    function repay(uint256 amount) external nonReentrant {
        drip();
        Vault storage v = vaults[msg.sender];
        uint256 debt = debtOf(msg.sender);
        if (amount > debt) amount = debt;
        if (amount == 0) revert ZeroAmount();
        uint256 norm = amount == debt ? v.normDebt : (amount * RAY) / rateAcc;
        v.normDebt -= norm;
        totalNormDebt -= norm;
        uint256 rem = debtOf(msg.sender);
        if (rem != 0 && rem < DUST) revert DustVault();
        stable.burn(msg.sender, amount);
        emit Repaid(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Liquidaciones
    // ------------------------------------------------------------------

    /// @notice Liquida parcialmente un vault bajo el LT. El liquidador quema `repayAmount`
    ///         de USD100 y recibe colateral por ese valor + 10% de premio.
    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        drip();
        Vault storage v = vaults[user];
        if (_isAbove(v, LT_BPS)) revert NotLiquidatable();
        uint256 debt = debtOf(user);
        // close factor: máx 50%, salvo que lo restante quede bajo el DUST (entonces se permite todo)
        uint256 maxRepay = (debt * CLOSE_FACTOR_BPS) / BPS;
        if (debt - maxRepay < DUST) maxRepay = debt;
        if (repayAmount > maxRepay) revert ExceedsCloseFactor();
        if (repayAmount == 0) revert ZeroAmount();

        uint256 price = _price(collateralFeed);
        uint256 seize = (repayAmount * 1e8 * (BPS + LIQ_BONUS_BPS)) / (price * BPS);
        uint256 norm = repayAmount == debt ? v.normDebt : (repayAmount * RAY) / rateAcc;

        if (seize > v.collateral) {
            // colateral insuficiente: se toma todo y la deuda remanente pasa a badDebt
            seize = v.collateral;
        }
        v.collateral -= seize;
        v.normDebt -= norm;
        totalNormDebt -= norm;
        if (v.collateral == 0 && v.normDebt > 0) {
            badDebt += (v.normDebt * rateAcc) / RAY;
            totalNormDebt -= v.normDebt;
            v.normDebt = 0;
        }
        stable.burn(msg.sender, repayAmount);
        collateral.safeTransfer(msg.sender, seize);
        emit Liquidated(user, msg.sender, repayAmount, seize);
    }

    // ------------------------------------------------------------------
    // Vistas
    // ------------------------------------------------------------------

    /// @notice Deuda actual (sin incluir interés pendiente de drip).
    function debtOf(address user) public view returns (uint256) {
        return _divUp(vaults[user].normDebt * rateAcc, RAY);
    }

    function totalDebt() public view returns (uint256) {
        return (totalNormDebt * rateAcc) / RAY;
    }

    /// @notice Ratio de colateralización en bps (type(uint256).max si no hay deuda).
    function collateralRatioBps(address user) external view returns (uint256) {
        return _ratio(vaults[user]);
    }

    function _ratio(Vault storage v) internal view returns (uint256) {
        if (v.normDebt == 0) return type(uint256).max;
        uint256 debt = _divUp(v.normDebt * rateAcc, RAY);
        uint256 value = (v.collateral * _price(collateralFeed)) / 1e8;
        return (value * BPS) / debt;
    }

    function _isAbove(Vault storage v, uint256 bps) internal view returns (bool) {
        return _ratio(v) >= bps;
    }

    /// @dev Precio validado: positivo y no viejo.
    function _price(IPriceFeed f) internal view returns (uint256) {
        (, int256 a,, uint256 updatedAt,) = f.latestRoundData();
        if (a <= 0) revert BadPrice();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();
        return uint256(a);
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ------------------------------------------------------------------
    // Gobernanza
    // ------------------------------------------------------------------
    function setDebtCeiling(uint256 c) external onlyOwner {
        debtCeiling = c;
    }

    function setTreasury(address t) external onlyOwner {
        treasury = t;
    }
}
