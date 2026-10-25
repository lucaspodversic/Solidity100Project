// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title OffsetOnlyVault — ERC-4626 de OpenZeppelin con **shares virtuales** y nada más
/// @notice Sigue usando `balanceOf` (acepta donaciones), pero con `_decimalsOffset() = 6`
///         la conversión es `shares = assets·(supply + 10^6) / (totalAssets + 1)`.
///         El atacante tendría que donar ~10^6 veces lo que quiere robar: el ataque deja de
///         ser rentable (pierde casi toda la donación, que se reparten las shares virtuales
///         y la víctima). Defensa *económica*, no absoluta.
contract OffsetOnlyVault is ERC4626 {
    constructor(IERC20 a) ERC20("Offset Vault", "oV") ERC4626(a) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
