// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NaiveVault — vault de shares **VULNERABLE** (solo con fines educativos)
/// @notice Reproduce los tres errores clásicos de contabilidad de shares:
///   1. **Activos = balanceOf(this):** cualquiera puede "donar" tokens y mover el precio por share.
///   2. **Primer depósito 1:1 sin shares virtuales:** con supply = 1 wei de share, una donación
///      hace que el siguiente depósito redondee a 0 shares (ataque de inflación).
///   3. **Redondeo a favor del usuario en `withdraw`:** las shares a quemar se redondean hacia
///      ABAJO, así que retirar montos chicos puede quemar 0 shares (retiro gratis).
/// @dev NO USAR. Ver `SafeVault` para la versión corregida.
contract NaiveVault is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    constructor(IERC20 _asset) ERC20("Naive Vault", "nV") {
        asset = _asset;
    }

    /// @notice ❌ Error 1: el balance del contrato es manipulable por donación.
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice shares = assets · supply / totalAssets  (redondeo hacia abajo).
    function deposit(uint256 assets) external returns (uint256 shares) {
        uint256 supply = totalSupply();
        // ❌ Error 2: sin offset virtual; si supply es 1 y totalAssets enorme, shares → 0
        shares = supply == 0 ? assets : (assets * supply) / totalAssets();
        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(msg.sender, shares); // ¡incluso si shares == 0! el depositante pierde todo
    }

    /// @notice assets = shares · totalAssets / supply (redondeo hacia abajo: correcto).
    function redeem(uint256 shares) external returns (uint256 assets) {
        assets = (shares * totalAssets()) / totalSupply();
        _burn(msg.sender, shares);
        asset.safeTransfer(msg.sender, assets);
    }

    /// @notice Retira `assets` exactos quemando las shares equivalentes.
    function withdraw(uint256 assets) external returns (uint256 shares) {
        // ❌ Error 3: debería redondear hacia ARRIBA. Con pps > 1, montos chicos queman 0 shares.
        shares = (assets * totalSupply()) / totalAssets();
        _burn(msg.sender, shares);
        asset.safeTransfer(msg.sender, assets);
    }
}
