// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Token de prueba con mint libre.
contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @notice Oráculo de precio (8 decimales): precio del colateral expresado en el activo prestable.
contract MockOracle {
    uint256 public price;
    constructor(uint256 p) { price = p; }
    function set(uint256 p) external { price = p; }
}

/// @notice DEX de precio fijo (usa el oráculo) para el bot de liquidación del test.
contract MockDex {
    MockOracle public oracle;
    constructor(MockOracle o) { oracle = o; }
    /// @notice Vende `amountIn` de colateral y entrega el activo prestable a precio de oráculo.
    function sell(IERC20 tokenIn, MockToken tokenOut, uint256 amountIn) external returns (uint256 out) {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        out = (amountIn * oracle.price()) / 1e8;
        tokenOut.mint(msg.sender, out);
    }
}
