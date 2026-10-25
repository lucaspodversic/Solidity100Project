// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title USD100 — Stablecoin emitida solo por el motor de CDPs
/// @notice Token ERC-20 cuyo mint/burn está reservado al `engine` inmutable.
contract Stablecoin is ERC20 {
    address public immutable engine;

    error OnlyEngine();

    constructor(address _engine) ERC20("Solidity100 USD", "USD100") {
        engine = _engine;
    }

    function mint(address to, uint256 a) external {
        if (msg.sender != engine) revert OnlyEngine();
        _mint(to, a);
    }

    function burn(address from, uint256 a) external {
        if (msg.sender != engine) revert OnlyEngine();
        _burn(from, a);
    }
}
