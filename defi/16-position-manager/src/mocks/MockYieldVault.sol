// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockYieldVault — vault ERC-4626 de prueba con rendimiento/pérdida manual
/// @notice `simulateYield` acuña activo al vault (sube el precio por share);
///         `simulateLoss` quema activo (hackeo/estrategia que pierde). Sólo para tests.
contract MockYieldVault is ERC4626 {
    constructor(IERC20 asset_, string memory n) ERC20(n, n) ERC4626(asset_) {}

    function simulateYield(uint256 amount) external {
        MockERC20(asset()).mint(address(this), amount);
    }

    function simulateLoss(uint256 amount) external {
        // transfiere a una dirección "quemada": el activo sale del vault
        IERC20(asset()).transfer(address(0xdead), amount);
    }

    /// @dev Offset de 6 decimales: defensa contra el ataque de inflación (ver proyecto 23).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
