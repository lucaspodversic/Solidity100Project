// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PriceOracle} from "../protocol/PriceOracle.sol";

/// @title OracleDex — DEX simulado que cotiza al precio del oráculo menos fee y slippage
/// @notice Sustituye a Uniswap en los tests: permite controlar exactamente la ejecución
///         (fee + slippage configurables) para probar cuándo una liquidación es rentable.
contract OracleDex {
    using SafeERC20 for IERC20;

    PriceOracle public immutable oracle;
    uint256 public feeBps = 30; // 0,3 %
    uint256 public slippageBps; // pérdida adicional simulada (profundidad del mercado)

    error Slippage();

    constructor(PriceOracle _oracle) {
        oracle = _oracle;
    }

    function setSlippage(uint256 bps) external {
        slippageBps = bps;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 usd = (amountIn * oracle.getPrice(tokenIn)) / 10 ** IERC20Metadata(tokenIn).decimals();
        uint256 out = (usd * 10 ** IERC20Metadata(tokenOut).decimals()) / oracle.getPrice(tokenOut);
        return (out * (10_000 - feeBps - slippageBps)) / 10_000;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) external returns (uint256 out) {
        out = quote(tokenIn, tokenOut, amountIn);
        if (out < minOut) revert Slippage();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, out);
    }
}
