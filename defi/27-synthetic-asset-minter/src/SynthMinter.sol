// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PriceOracle} from "./oracle/PriceOracle.sol";
import {SyntheticAsset} from "./SyntheticAsset.sol";

/// @title SynthMinter — CDPs (estilo MakerDAO / Synthetix v1 / Mirror) que emiten un activo sintético
/// @notice Depositás WETH y acuñás `sAsset`, un token que sigue el precio de otro activo
///         (oro, una acción, un índice…) según el oráculo. Mecanismos de estabilidad:
///   - **Ratio de colateral mínimo (MCR) 150 %** para acuñar o retirar.
///   - **Liquidación** por debajo de 120 %: cualquiera repaga hasta el 50 % de la deuda con
///     sAsset y se lleva WETH equivalente + 10 % de penalidad. Esto da a los arbitrajistas
///     un motivo para *comprar* sAsset en el mercado cuando hay riesgo → sostiene el peg.
///   - **Stability fee** (interés anual sobre la deuda) mediante un índice acumulador como el
///     `rate` de Maker: subirla encarece la deuda, la gente quema sAsset y el precio sube;
///     bajarla abarata acuñar y el precio baja. Es la "tasa de interés" del sintético.
///   - **Techo de deuda** global para limitar la exposición al oráculo.
///   - **Deuda incobrable** contabilizada y cubrible con el excedente de fees (`healBadDebt`).
contract SynthMinter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    IERC20 public immutable collateral; // WETH
    SyntheticAsset public immutable synth;
    PriceOracle public immutable oracle;
    address public treasury;

    uint256 public mcrBps = 15_000; // 150 %
    uint256 public liquidationRatioBps = 12_000; // 120 %
    uint256 public liquidationPenaltyBps = 1_000; // 10 %
    uint256 public closeFactorBps = 5_000; // 50 % por liquidación
    /// @notice Stability fee anual (WAD, 0.05e18 = 5 %/año, interés simple por intervalo).
    uint256 public stabilityFee = 0.05e18;
    uint256 public debtCeiling;

    /// @notice Índice acumulador: deuda real = normDebt · rateIndex / WAD.
    uint256 public rateIndex = WAD;
    uint256 public lastAccrual;
    uint256 public totalNormDebt;
    /// @notice Deuda sin respaldo (tras liquidaciones con colateral insuficiente).
    uint256 public badDebt;

    struct Vault {
        uint256 collateral;
        uint256 normDebt;
    }

    mapping(address => Vault) public vaults;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Minted(address indexed user, uint256 amount);
    event Burned(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 repaid, uint256 seized, uint256 badDebt);
    event Accrued(uint256 rateIndex, uint256 feesMinted);
    event BadDebtHealed(uint256 amount);

    error ZeroAmount();
    error BelowMCR(uint256 ratioBps);
    error DebtCeilingExceeded();
    error NotLiquidatable(uint256 ratioBps);
    error ParamsInvalid();

    constructor(IERC20 collateral_, PriceOracle oracle_, address treasury_, uint256 debtCeiling_, string memory n, string memory s)
        Ownable(msg.sender)
    {
        collateral = collateral_;
        oracle = oracle_;
        treasury = treasury_;
        debtCeiling = debtCeiling_;
        synth = new SyntheticAsset(n, s, address(this));
        lastAccrual = block.timestamp;
    }

    // =====================================================================
    // Stability fee
    // =====================================================================

    /// @notice Índice proyectado a ahora (interés simple en el intervalo, compuesto entre llamadas).
    function currentRateIndex() public view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0) return rateIndex;
        return rateIndex + Math.mulDiv(rateIndex, stabilityFee * dt, WAD * YEAR);
    }

    /// @notice Persiste el índice y acuña al tesoro el sAsset correspondiente a las fees
    ///         (es el "surplus" de Maker: deuda nueva de los usuarios = sAsset nuevo del sistema).
    function accrue() public {
        uint256 newIdx = currentRateIndex();
        if (newIdx == rateIndex) {
            lastAccrual = block.timestamp;
            return;
        }
        uint256 before = Math.mulDiv(totalNormDebt, rateIndex, WAD);
        uint256 after_ = Math.mulDiv(totalNormDebt, newIdx, WAD);
        rateIndex = newIdx;
        lastAccrual = block.timestamp;
        uint256 fees = after_ - before;
        if (fees > 0) synth.mint(treasury, fees);
        emit Accrued(newIdx, fees);
    }

    // =====================================================================
    // Operaciones del usuario
    // =====================================================================

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        vaults[msg.sender].collateral += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrue();
        vaults[msg.sender].collateral -= amount;
        _requireMCR(msg.sender);
        collateral.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Acuña `amount` de sAsset contra el colateral propio.
    function mint(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrue();
        // la deuda normalizada se redondea hacia ARRIBA (a favor del sistema)
        uint256 norm = Math.mulDiv(amount, WAD, rateIndex, Math.Rounding.Ceil);
        vaults[msg.sender].normDebt += norm;
        totalNormDebt += norm;
        if (totalDebt() > debtCeiling) revert DebtCeilingExceeded();
        _requireMCR(msg.sender);
        synth.mint(msg.sender, amount);
        emit Minted(msg.sender, amount);
    }

    /// @notice Repaga deuda quemando sAsset. `type(uint256).max` = repagar todo.
    function burn(uint256 amount) external nonReentrant {
        accrue();
        Vault storage v = vaults[msg.sender];
        uint256 debt = debtOf(msg.sender);
        if (amount > debt) amount = debt;
        if (amount == 0) revert ZeroAmount();
        uint256 norm = amount == debt ? v.normDebt : Math.mulDiv(amount, WAD, rateIndex);
        v.normDebt -= norm;
        totalNormDebt -= norm;
        synth.burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }

    // =====================================================================
    // Liquidación
    // =====================================================================

    /// @notice Repaga hasta `closeFactor` de la deuda de `user` y se lleva colateral con bonus.
    function liquidate(address user, uint256 repay) external nonReentrant returns (uint256 seized) {
        accrue();
        uint256 ratio = collateralRatio(user);
        if (ratio >= liquidationRatioBps) revert NotLiquidatable(ratio);
        Vault storage v = vaults[user];
        uint256 debt = debtOf(user);
        uint256 maxRepay = Math.mulDiv(debt, closeFactorBps, BPS);
        if (repay > maxRepay) repay = maxRepay;
        if (repay == 0) revert ZeroAmount();

        // valor del repago en WETH + penalidad
        seized = Math.mulDiv(repay * _synthPrice(), BPS + liquidationPenaltyBps, _collPrice() * BPS);
        if (seized > v.collateral) {
            // colateral insuficiente: se lleva todo y repaga en proporción
            seized = v.collateral;
            repay = Math.mulDiv(seized, _collPrice() * BPS, _synthPrice() * (BPS + liquidationPenaltyBps));
        }

        synth.burn(msg.sender, repay);
        uint256 norm = Math.mulDiv(repay, WAD, rateIndex);
        if (norm > v.normDebt) norm = v.normDebt;
        v.normDebt -= norm;
        v.collateral -= seized;
        totalNormDebt -= norm;

        // si no quedó colateral, la deuda restante es incobrable: sale del vault y se registra
        uint256 bd;
        if (v.collateral == 0 && v.normDebt > 0) {
            bd = Math.mulDiv(v.normDebt, rateIndex, WAD);
            totalNormDebt -= v.normDebt;
            v.normDebt = 0;
            badDebt += bd;
        }
        collateral.safeTransfer(msg.sender, seized);
        emit Liquidated(user, msg.sender, repay, seized, bd);
    }

    /// @notice El tesoro quema sAsset de fees para cancelar deuda incobrable.
    function healBadDebt(uint256 amount) external {
        if (amount > badDebt) amount = badDebt;
        synth.burn(msg.sender, amount);
        badDebt -= amount;
        emit BadDebtHealed(amount);
    }

    // =====================================================================
    // Vistas
    // =====================================================================

    function debtOf(address user) public view returns (uint256) {
        return Math.mulDiv(vaults[user].normDebt, currentRateIndex(), WAD, Math.Rounding.Ceil);
    }

    function totalDebt() public view returns (uint256) {
        return Math.mulDiv(totalNormDebt, currentRateIndex(), WAD);
    }

    /// @notice Valor del colateral / valor de la deuda, en bps (max si no hay deuda).
    function collateralRatio(address user) public view returns (uint256) {
        uint256 debt = debtOf(user);
        if (debt == 0) return type(uint256).max;
        return Math.mulDiv(vaults[user].collateral * _collPrice(), BPS, debt * _synthPrice());
    }

    /// @notice Cuánto más puede acuñar `user` sin bajar del MCR.
    function maxMintable(address user) external view returns (uint256) {
        uint256 cap = Math.mulDiv(vaults[user].collateral * _collPrice(), BPS, mcrBps * _synthPrice());
        uint256 debt = debtOf(user);
        return cap > debt ? cap - debt : 0;
    }

    /// @notice Precio del colateral al que `user` queda liquidable.
    function liquidationPrice(address user) external view returns (uint256) {
        Vault memory v = vaults[user];
        if (v.collateral == 0) return 0;
        return Math.mulDiv(debtOf(user) * _synthPrice(), liquidationRatioBps, v.collateral * BPS);
    }

    // =====================================================================
    // Admin
    // =====================================================================

    function setStabilityFee(uint256 fee) external onlyOwner {
        if (fee > 1e18) revert ParamsInvalid(); // máx 100 %/año
        accrue(); // lo devengado hasta ahora se cobra con la tasa vieja
        stabilityFee = fee;
    }

    function setRisk(uint256 mcr, uint256 liqRatio, uint256 penalty) external onlyOwner {
        if (liqRatio <= BPS || mcr <= liqRatio || penalty >= liqRatio - BPS) revert ParamsInvalid();
        mcrBps = mcr;
        liquidationRatioBps = liqRatio;
        liquidationPenaltyBps = penalty;
    }

    function setDebtCeiling(uint256 c) external onlyOwner {
        debtCeiling = c;
    }

    // ---------------------------------------------------------------------

    function _requireMCR(address user) internal view {
        uint256 r = collateralRatio(user);
        if (r < mcrBps) revert BelowMCR(r);
    }

    function _collPrice() internal view returns (uint256) {
        return oracle.getPrice(address(collateral));
    }

    function _synthPrice() internal view returns (uint256) {
        return oracle.getPrice(address(synth));
    }
}
