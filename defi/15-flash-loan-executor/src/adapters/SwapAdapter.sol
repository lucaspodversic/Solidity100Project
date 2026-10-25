// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "./IAdapter.sol";
import {SimpleAMM} from "../mocks/SimpleAMM.sol";

/// @title SwapAdapter — swap en un AMM
/// @notice data = abi.encode(dex, tokenIn, amountIn, minOut). Si amountIn == USE_PREV,
///         usa la salida del paso anterior; si es USE_BALANCE, todo el balance de tokenIn.
contract SwapAdapter is IAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant USE_PREV = type(uint256).max;
    uint256 public constant USE_BALANCE = type(uint256).max - 1;

    function execute(bytes calldata data, uint256 prev) external payable returns (uint256 out) {
        (address dex, address tokenIn, uint256 amountIn, uint256 minOut) =
            abi.decode(data, (address, address, uint256, uint256));
        if (amountIn == USE_PREV) amountIn = prev;
        else if (amountIn == USE_BALANCE) amountIn = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(dex, amountIn);
        out = SimpleAMM(dex).swap(tokenIn, amountIn, minOut, address(this));
    }
}
