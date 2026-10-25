// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SafeVault — vault ERC-4626 con defensa en profundidad contra donación y redondeo
/// @notice Capas de defensa:
///   1. **Contabilidad interna** (`_managed`): los activos se cuentan al depositar/retirar, no con
///      `balanceOf`. Una donación NO cambia el precio por share (el owner puede `skim`earla).
///   2. **Shares virtuales** (offset 6): aunque la contabilidad fallara, el ataque de inflación
///      sería antieconómico.
///   3. **Redondeo a favor del vault** (heredado de OZ): `deposit/redeem` hacia abajo,
///      `mint/withdraw` hacia arriba. Nadie extrae valor con montos de polvo.
///   4. **Protección de slippage** opcional para el usuario: `depositWithMin`, `redeemWithMin`.
contract SafeVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    /// @dev Activos contabilizados (solo cambian por depósitos, retiros y `reportYield`).
    uint256 private _managed;

    error SlippageExceeded();

    constructor(IERC20 a) ERC20("Safe Vault", "sV") ERC4626(a) Ownable(msg.sender) {}

    /// @notice Activos según la contabilidad interna (inmune a donaciones).
    function totalAssets() public view override returns (uint256) {
        return _managed;
    }

    /// @notice Tokens que llegaron por fuera de `deposit` (donaciones o envíos por error).
    function excess() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - _managed;
    }

    /// @notice Reconoce como rendimiento un monto ya presente en el contrato (acción de gobernanza;
    ///         en un vault real lo haría la estrategia con su propio desbloqueo gradual).
    function reportYield(uint256 amount) external onlyOwner {
        require(amount <= excess(), "sin respaldo");
        _managed += amount;
    }

    /// @notice Envía el excedente (donaciones) a `to`.
    function skim(address to) external onlyOwner {
        IERC20(asset()).safeTransfer(to, excess());
    }

    /// @notice `deposit` con mínimo de shares (protege contra front-running del depositante).
    function depositWithMin(uint256 assets, address receiver, uint256 minShares) external returns (uint256 s) {
        s = deposit(assets, receiver);
        if (s < minShares) revert SlippageExceeded();
    }

    /// @notice `redeem` con mínimo de activos.
    function redeemWithMin(uint256 shares, address receiver, uint256 minAssets) external returns (uint256 a) {
        a = redeem(shares, receiver, msg.sender);
        if (a < minAssets) revert SlippageExceeded();
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // Guard extra: un depósito que no da shares es una pérdida segura para el usuario.
        require(shares > 0, "0 shares");
        _managed += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        _managed -= assets;
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
