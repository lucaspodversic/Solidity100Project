// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title SyntheticAsset — token sintético (p.ej. sXAU) que solo el minter puede emitir/quemar
contract SyntheticAsset is ERC20, ERC20Permit {
    address public immutable minter;

    error OnlyMinter();

    constructor(string memory n, string memory s, address minter_) ERC20(n, s) ERC20Permit(n) {
        minter = minter_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _burn(from, amount);
    }
}
