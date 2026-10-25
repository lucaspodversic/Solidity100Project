// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VenueBase} from "./VenueBase.sol";

/// @title ERC4626Venue — posición en cualquier vault ERC-4626
/// @notice Gracias al estándar, un único adaptador sirve para Yearn, Morpho vaults, sDAI, etc.
contract ERC4626Venue is VenueBase {
    using SafeERC20 for IERC20;

    IERC4626 public immutable vault;

    constructor(address _manager, IERC4626 _vault) VenueBase(_manager, IERC20(_vault.asset())) {
        vault = _vault;
        IERC20(_vault.asset()).forceApprove(address(_vault), type(uint256).max);
    }

    /// @notice Valor de nuestras shares (convertToAssets redondea hacia abajo: estimación conservadora).
    function totalAssets() external view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    function maxWithdraw() external view returns (uint256) {
        return vault.maxWithdraw(address(this));
    }

    function deposit(uint256 amount) external onlyManager {
        _asset.safeTransferFrom(msg.sender, address(this), amount);
        vault.deposit(amount, address(this));
    }

    /// @dev Usa `withdraw` (assets exactos) salvo que pidan todo: ahí `redeem` de todas las
    ///      shares evita dejar polvo de shares por redondeo.
    function withdraw(uint256 amount) external onlyManager returns (uint256 received) {
        uint256 max = vault.maxWithdraw(address(this));
        if (amount >= max) {
            received = vault.redeem(vault.balanceOf(address(this)), manager, address(this));
        } else {
            vault.withdraw(amount, manager, address(this));
            received = amount;
        }
    }

    function name() external view returns (string memory) {
        return string.concat("ERC4626 ", vault.name());
    }
}
