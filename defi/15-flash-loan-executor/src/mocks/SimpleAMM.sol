// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SimpleAMM — par x·y=k mínimo (fee 0,3 %) para los tests y scripts
/// @notice Versión compacta del CPAMM del proyecto 01: sin LP tokens, la liquidez se
///         inicializa con `seed`. Suficiente para crear diferencias de precio entre DEXes.
contract SimpleAMM {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint256 public reserve0;
    uint256 public reserve1;

    error Slippage();
    error BadToken();

    constructor(IERC20 _t0, IERC20 _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function seed(uint256 a0, uint256 a1) external {
        token0.safeTransferFrom(msg.sender, address(this), a0);
        token1.safeTransferFrom(msg.sender, address(this), a1);
        reserve0 += a0;
        reserve1 += a1;
    }

    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        (uint256 rIn, uint256 rOut) = tokenIn == address(token0) ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 inFee = amountIn * 997;
        return (inFee * rOut) / (rIn * 1000 + inFee);
    }

    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out) {
        if (tokenIn != address(token0) && tokenIn != address(token1)) revert BadToken();
        out = getAmountOut(tokenIn, amountIn);
        if (out < minOut) revert Slippage();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (tokenIn == address(token0)) {
            reserve0 += amountIn;
            reserve1 -= out;
            token1.safeTransfer(to, out);
        } else {
            reserve1 += amountIn;
            reserve0 -= out;
            token0.safeTransfer(to, out);
        }
    }
}
