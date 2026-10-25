// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Colateral de prueba (p. ej. WETH) con mint libre.
contract MockCollateral is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @notice Oráculo estilo Chainlink (8 decimales) controlable en tests.
contract MockOracle {
    int256 public answer;
    uint256 public updatedAt;
    constructor(int256 a) { set(a); }
    function set(int256 a) public { answer = a; updatedAt = block.timestamp; }
    function setStale(uint256 t) external { updatedAt = t; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}
