// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../Interfaces.sol";

/// @notice Oráculo de prueba con precio configurable (escala 1e36).
contract MockOracle is IOracle {
    uint256 public price;

    function setPrice(uint256 p) external {
        price = p;
    }
}
