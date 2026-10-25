// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";

/// @title PriceConsumer — Consumidor genérico que acepta cualquiera de las tres arquitecturas
/// @notice Muestra el patrón correcto de consumo: validar frescura y valor positivo.
contract PriceConsumer {
    IOracle public immutable oracle;
    uint256 public immutable maxAge;

    error Stale();
    error Zero();

    constructor(IOracle o, uint256 _maxAge) {
        oracle = o;
        maxAge = _maxAge;
    }

    function price() external view returns (uint256 v) {
        uint256 t;
        (v, t) = oracle.latest();
        if (v == 0) revert Zero();
        if (block.timestamp - t > maxAge) revert Stale();
    }
}
