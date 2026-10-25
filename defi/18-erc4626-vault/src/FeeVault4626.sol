// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FeeVault4626 — implementación ERC-4626 "desde cero" con fees y límites
/// @notice A diferencia de heredar `ERC4626` de OpenZeppelin, acá se escribe toda la
///         matemática del estándar para estudiarla:
///           * conversión assets ↔ shares con **shares virtuales** (anti-inflación),
///           * redondeo SIEMPRE a favor del vault (EIP-4626, sección "Security"),
///           * management fee anual + performance fee sobre **high-water mark**, cobrados
///             como dilución (se acuñan shares al tesoro) y reflejados en los `preview*`,
///           * tope de depósitos (`depositCap`) y pausa, reflejados en `max*`.
/// @dev El rendimiento llega al vault como transferencias de activo (en producción vendría
///      de una estrategia; en los tests se simula con `mint` al vault).
contract FeeVault4626 is ERC20, IERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 public constant MAX_MGMT_FEE = 500; // 5 %/año
    uint256 public constant MAX_PERF_FEE = 3_000; // 30 % de la ganancia

    IERC20 private immutable _asset;
    uint8 private immutable _assetDecimals;
    /// @notice Offset de decimales: 10^OFFSET shares virtuales (ver proyecto 23).
    uint8 public constant OFFSET = 6;

    address public treasury;
    uint256 public managementFeeBps; // anual
    uint256 public performanceFeeBps;
    uint256 public depositCap; // en assets; max = sin tope
    bool public paused;

    /// @notice Último cobro de fees.
    uint256 public lastFeeAccrual;
    /// @notice High-water mark: assets por 1e18 shares (sólo se cobra performance por encima).
    uint256 public highWaterMark;

    event FeesAccrued(uint256 mgmtShares, uint256 perfShares, uint256 newHwm);
    event ParamsSet(address treasury, uint256 mgmt, uint256 perf, uint256 cap);
    event Paused(bool paused);

    error ExceedsMax(uint256 requested, uint256 max);
    error ZeroShares();
    error BadFee();

    constructor(IERC20 asset_, string memory n, string memory s, address _treasury)
        ERC20(n, s)
        Ownable(msg.sender)
    {
        _asset = asset_;
        _assetDecimals = IERC20Metadata(address(asset_)).decimals();
        treasury = _treasury;
        depositCap = type(uint256).max;
        lastFeeAccrual = block.timestamp;
        highWaterMark = _pricePerShare(0, 0);
    }

    // ------------------------------------------------------------------
    // Metadatos
    // ------------------------------------------------------------------

    /// @notice Las shares tienen los decimales del activo + OFFSET.
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _assetDecimals + OFFSET;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    /// @notice Todo lo que el vault custodia. (Sin estrategia: el saldo del contrato.)
    function totalAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    // ------------------------------------------------------------------
    // Fees (dilución)
    // ------------------------------------------------------------------

    /// @notice Precio por 1e18 shares, incluyendo las shares virtuales.
    function _pricePerShare(uint256 assets_, uint256 supply_) internal pure returns (uint256) {
        return (assets_ + 1).mulDiv(1e18, supply_ + 10 ** OFFSET);
    }

    /// @notice Shares que se acuñarían al tesoro si se cobraran las fees AHORA.
    /// @dev Se usa en vistas para que `preview*` y `convertTo*` reflejen las fees pendientes:
    ///      si no, un usuario podría entrar justo antes del cobro y esquivarlas.
    function _pendingFees() internal view returns (uint256 mgmtShares, uint256 perfShares, uint256 newHwm) {
        uint256 supply = totalSupply();
        uint256 assets_ = totalAssets();
        newHwm = highWaterMark;
        if (supply == 0) return (0, 0, _pricePerShare(assets_, 0));

        // Management: diluye supply·fee·dt/año (aproximación lineal estándar)
        uint256 dt = block.timestamp - lastFeeAccrual;
        mgmtShares = supply.mulDiv(managementFeeBps * dt, BPS * YEAR);
        uint256 supplyAfterMgmt = supply + mgmtShares;

        // Performance: fee sobre la ganancia por share por encima del high-water mark
        uint256 pps = _pricePerShare(assets_, supplyAfterMgmt);
        if (pps > highWaterMark && performanceFeeBps > 0) {
            uint256 profit = (pps - highWaterMark).mulDiv(supplyAfterMgmt + 10 ** OFFSET, 1e18);
            uint256 feeAssets = profit.mulDiv(performanceFeeBps, BPS);
            // shares tales que shares/(supply+shares) = feeAssets/assets
            perfShares = feeAssets.mulDiv(supplyAfterMgmt + 10 ** OFFSET, assets_ + 1 - feeAssets);
            newHwm = _pricePerShare(assets_, supplyAfterMgmt + perfShares);
        } else if (pps > highWaterMark) {
            newHwm = pps;
        }
    }

    /// @notice Cobra las fees pendientes (lo llama cada operación; también público).
    function accrueFees() public {
        (uint256 m, uint256 p, uint256 hwm) = _pendingFees();
        lastFeeAccrual = block.timestamp;
        highWaterMark = hwm;
        if (m + p > 0) _mint(treasury, m + p);
        emit FeesAccrued(m, p, hwm);
    }

    /// @dev Supply efectivo para conversiones = real + fees pendientes.
    function _effectiveSupply() internal view returns (uint256) {
        (uint256 m, uint256 p,) = _pendingFees();
        return totalSupply() + m + p;
    }

    // ------------------------------------------------------------------
    // Conversión (con shares virtuales)
    // ------------------------------------------------------------------

    /// @dev shares = assets · (supply + 10^off) / (totalAssets + 1)
    function _toShares(uint256 assets_, Math.Rounding r) internal view returns (uint256) {
        return assets_.mulDiv(_effectiveSupply() + 10 ** OFFSET, totalAssets() + 1, r);
    }

    /// @dev assets = shares · (totalAssets + 1) / (supply + 10^off)
    function _toAssets(uint256 shares, Math.Rounding r) internal view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, _effectiveSupply() + 10 ** OFFSET, r);
    }

    function convertToShares(uint256 assets_) external view returns (uint256) {
        return _toShares(assets_, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _toAssets(shares, Math.Rounding.Floor);
    }

    // ------------------------------------------------------------------
    // Límites
    // ------------------------------------------------------------------

    function maxDeposit(address) public view returns (uint256) {
        if (paused) return 0;
        uint256 ta = totalAssets();
        return ta >= depositCap ? 0 : depositCap - ta;
    }

    function maxMint(address r) external view returns (uint256) {
        uint256 a = maxDeposit(r);
        return a == type(uint256).max ? a : _toShares(a, Math.Rounding.Floor);
    }

    /// @notice Retirar se permite aún en pausa: la pausa frena entradas, nunca encierra fondos.
    function maxWithdraw(address o) public view returns (uint256) {
        return _toAssets(balanceOf(o), Math.Rounding.Floor);
    }

    function maxRedeem(address o) public view returns (uint256) {
        return balanceOf(o);
    }

    // ------------------------------------------------------------------
    // Previews (redondeo a favor del vault)
    // ------------------------------------------------------------------

    /// @notice Shares que recibo por `assets` (hacia abajo: recibo menos).
    function previewDeposit(uint256 assets_) public view returns (uint256) {
        return _toShares(assets_, Math.Rounding.Floor);
    }

    /// @notice Assets que pago por `shares` (hacia arriba: pago más).
    function previewMint(uint256 shares) public view returns (uint256) {
        return _toAssets(shares, Math.Rounding.Ceil);
    }

    /// @notice Shares que quemo para sacar `assets` (hacia arriba: quemo más).
    function previewWithdraw(uint256 assets_) public view returns (uint256) {
        return _toShares(assets_, Math.Rounding.Ceil);
    }

    /// @notice Assets que recibo por quemar `shares` (hacia abajo: recibo menos).
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _toAssets(shares, Math.Rounding.Floor);
    }

    // ------------------------------------------------------------------
    // Operaciones
    // ------------------------------------------------------------------

    function deposit(uint256 assets_, address receiver) external nonReentrant returns (uint256 shares) {
        accrueFees(); // primero las fees: el precio queda "al día" para este usuario
        uint256 max = maxDeposit(receiver);
        if (assets_ > max) revert ExceedsMax(assets_, max);
        shares = previewDeposit(assets_);
        if (shares == 0) revert ZeroShares();
        _enter(receiver, assets_, shares);
    }

    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets_) {
        accrueFees();
        assets_ = previewMint(shares);
        uint256 max = maxDeposit(receiver);
        if (assets_ > max) revert ExceedsMax(assets_, max);
        _enter(receiver, assets_, shares);
    }

    function withdraw(uint256 assets_, address receiver, address owner_)
        external
        nonReentrant
        returns (uint256 shares)
    {
        accrueFees();
        uint256 max = maxWithdraw(owner_);
        if (assets_ > max) revert ExceedsMax(assets_, max);
        shares = previewWithdraw(assets_);
        _exit(msg.sender, receiver, owner_, assets_, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        external
        nonReentrant
        returns (uint256 assets_)
    {
        accrueFees();
        uint256 max = maxRedeem(owner_);
        if (shares > max) revert ExceedsMax(shares, max);
        assets_ = previewRedeem(shares);
        _exit(msg.sender, receiver, owner_, assets_, shares);
    }

    /// @dev Checks-effects-interactions: primero se cobra el activo, después se acuñan shares.
    function _enter(address receiver, uint256 assets_, uint256 shares) internal {
        _asset.safeTransferFrom(msg.sender, address(this), assets_);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets_, shares);
    }

    /// @dev Si el caller no es el owner de las shares, consume allowance (como transferFrom).
    function _exit(address caller, address receiver, address owner_, uint256 assets_, uint256 shares) internal {
        if (caller != owner_) _spendAllowance(owner_, caller, shares);
        _burn(owner_, shares);
        _asset.safeTransfer(receiver, assets_);
        emit Withdraw(caller, receiver, owner_, assets_, shares);
    }

    // ------------------------------------------------------------------
    // Administración
    // ------------------------------------------------------------------

    /// @notice Cambiar fees cobra antes lo pendiente con las fees VIEJAS (no retroactivo).
    function setParams(address _treasury, uint256 mgmt, uint256 perf, uint256 cap) external onlyOwner {
        if (mgmt > MAX_MGMT_FEE || perf > MAX_PERF_FEE) revert BadFee();
        accrueFees();
        treasury = _treasury;
        managementFeeBps = mgmt;
        performanceFeeBps = perf;
        depositCap = cap;
        emit ParamsSet(_treasury, mgmt, perf, cap);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }
}
