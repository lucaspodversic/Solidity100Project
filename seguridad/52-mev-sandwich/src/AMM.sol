// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MiniAMM — x*y=k para simular sandwich MEV
contract MiniAMM {
    uint256 public reserveA;
    uint256 public reserveB;
    constructor(uint256 a, uint256 b) { reserveA = a; reserveB = b; }
    function price() public view returns (uint256) { return (reserveB * 1e18) / reserveA; }

    /// @notice Swap A→B. `minOut` es la protección slippage del usuario.
    function swapAforB(uint256 amountA, uint256 minOut) external returns (uint256 outB) {
        outB = (amountA * reserveB) / (reserveA + amountA);
        require(outB >= minOut, "slippage");
        reserveA += amountA;
        reserveB -= outB;
    }
    function swapBforA(uint256 amountB, uint256 minOut) external returns (uint256 outA) {
        outA = (amountB * reserveA) / (reserveB + amountB);
        require(outA >= minOut, "slippage");
        reserveB += amountB;
        reserveA -= outA;
    }
}
