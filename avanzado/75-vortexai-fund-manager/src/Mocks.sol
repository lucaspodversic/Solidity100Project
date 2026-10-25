// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Token de prueba con mint libre (SOLO tests). WETH y USDC usan 18 decimales para simplificar.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice Oráculo de precio de WETH en USDC (1e18 = 1 USDC por WETH). Simula Chainlink o un TWAP.
contract MockOracle {
    uint256 public price;

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title MockAMM — Pool x·y=k (estilo Uniswap V2) WETH/USDC con fee del 0,3% y LP ERC-20
contract MockAMM is ERC20 {
    IERC20 public immutable tokenA; // WETH
    IERC20 public immutable tokenB; // USDC
    uint256 public reserveA;
    uint256 public reserveB;

    error Slippage();
    error BadToken();

    constructor(IERC20 a, IERC20 b) ERC20("Vortex LP", "VLP") {
        tokenA = a;
        tokenB = b;
    }

    /// @notice Precio spot de A en B (1e18).
    function spotPrice() external view returns (uint256) {
        return (reserveB * 1e18) / reserveA;
    }

    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        (uint256 rIn, uint256 rOut) = tokenIn == address(tokenA) ? (reserveA, reserveB) : (reserveB, reserveA);
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * rOut) / (rIn * 1000 + inWithFee);
    }

    function swap(address tokenIn, uint256 amountIn, uint256 minOut) external returns (uint256 out) {
        if (tokenIn != address(tokenA) && tokenIn != address(tokenB)) revert BadToken();
        out = getAmountOut(tokenIn, amountIn);
        if (out < minOut) revert Slippage();
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (tokenIn == address(tokenA)) {
            reserveA += amountIn;
            reserveB -= out;
            tokenB.transfer(msg.sender, out);
        } else {
            reserveB += amountIn;
            reserveA -= out;
            tokenA.transfer(msg.sender, out);
        }
    }

    /// @notice Agrega liquidez usando solo la proporción óptima (como Router V2).
    function addLiquidity(uint256 a, uint256 b) external returns (uint256 lp, uint256 usedA, uint256 usedB) {
        uint256 s = totalSupply();
        if (s == 0) {
            (usedA, usedB) = (a, b);
            lp = Math.sqrt(a * b);
        } else {
            uint256 bOpt = (a * reserveB) / reserveA;
            if (bOpt <= b) (usedA, usedB) = (a, bOpt);
            else (usedA, usedB) = ((b * reserveA) / reserveB, b);
            lp = Math.min((usedA * s) / reserveA, (usedB * s) / reserveB);
        }
        tokenA.transferFrom(msg.sender, address(this), usedA);
        tokenB.transferFrom(msg.sender, address(this), usedB);
        reserveA += usedA;
        reserveB += usedB;
        _mint(msg.sender, lp);
    }

    function removeLiquidity(uint256 lp) external returns (uint256 a, uint256 b) {
        uint256 s = totalSupply();
        a = (lp * reserveA) / s;
        b = (lp * reserveB) / s;
        _burn(msg.sender, lp);
        reserveA -= a;
        reserveB -= b;
        tokenA.transfer(msg.sender, a);
        tokenB.transfer(msg.sender, b);
    }
}
