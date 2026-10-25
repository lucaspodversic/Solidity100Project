// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RebaseToken} from "./RebaseToken.sol";

/// @title Vault — Depósito de ETH 1:1 en RebaseToken (solo en la cadena "origen")
/// @notice deposit(): ETH → RBT a la tasa global vigente. redeem(): RBT (con intereses) → ETH.
///         Los intereses se pagan del ETH de recompensas que el protocolo envía al vault.
contract Vault is ReentrancyGuard {
    RebaseToken public immutable token;

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    error ZeroAmount();
    error SendFailed();

    constructor(RebaseToken t) {
        token = t;
    }

    /// @notice Recibe recompensas (fondeo de intereses).
    receive() external payable {}

    function deposit() external payable {
        if (msg.value == 0) revert ZeroAmount();
        token.mint(msg.sender, msg.value, token.globalRate());
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Quema `amount` (o todo con max) y devuelve ETH.
    function redeem(uint256 amount) external nonReentrant {
        uint256 burned = token.burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: burned}("");
        if (!ok) revert SendFailed();
        emit Redeem(msg.sender, burned);
    }
}
