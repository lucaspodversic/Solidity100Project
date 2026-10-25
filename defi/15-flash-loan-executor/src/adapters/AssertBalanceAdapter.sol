// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdapter} from "./IAdapter.sol";

/// @title AssertBalanceAdapter — "guardia" intermedia en la cadena
/// @notice data = abi.encode(token, minBalance). Revierte si el executor tiene menos.
///         Deja pasar `prev` sin cambios (no rompe el encadenamiento).
contract AssertBalanceAdapter is IAdapter {
    error BalanceTooLow(address token, uint256 have, uint256 want);

    function execute(bytes calldata data, uint256 prev) external payable returns (uint256) {
        (address token, uint256 minBal) = abi.decode(data, (address, uint256));
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < minBal) revert BalanceTooLow(token, bal, minBal);
        return prev;
    }
}
