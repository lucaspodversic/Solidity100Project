// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CPAMMFactory} from "./amm/CPAMMFactory.sol";
import {OracleLibrary} from "./libraries/OracleLibrary.sol";

/// @title SlidingWindowOracle — TWAP de ventana deslizante para cualquier par de la fábrica
/// @notice Guarda `granularity` observaciones por par en un buffer circular. Cada consulta
///         promedia desde la observación más vieja de la ventana hasta "ahora" (contrafactual),
///         así el precio siempre cubre aproximadamente `windowSize` segundos y nunca está viejo
///         más que `periodSize`.
/// @dev Más granularidad = ventana más precisa, pero más updates (gas de keepers).
contract SlidingWindowOracle {
    struct Observation {
        uint32 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    CPAMMFactory public immutable factory;
    /// @notice Duración de la ventana deslizante.
    uint256 public immutable windowSize;
    /// @notice Cantidad de observaciones guardadas por ventana.
    uint8 public immutable granularity;
    /// @notice windowSize / granularity.
    uint256 public immutable periodSize;

    /// @notice Buffer circular de observaciones por par.
    mapping(address => Observation[]) public pairObservations;

    event Observed(address indexed pair, uint8 index, uint32 timestamp);

    error BadGranularity();
    error PairNotFound();
    error MissingHistoricalObservation();
    error UnexpectedTimeElapsed();
    error InvalidToken();

    constructor(CPAMMFactory _factory, uint256 _windowSize, uint8 _granularity) {
        if (_granularity <= 1) revert BadGranularity();
        if ((_windowSize / _granularity) * _granularity != _windowSize) revert BadGranularity();
        factory = _factory;
        windowSize = _windowSize;
        granularity = _granularity;
        periodSize = _windowSize / _granularity;
    }

    /// @notice Slot del buffer correspondiente a un timestamp.
    function observationIndexOf(uint256 timestamp) public view returns (uint8) {
        return uint8((timestamp / periodSize) % granularity);
    }

    /// @dev Observación más vieja de la ventana: la siguiente al slot actual.
    function _firstObservationInWindow(address pair) private view returns (Observation storage) {
        uint8 idx = observationIndexOf(block.timestamp);
        uint8 first = (idx + 1) % granularity;
        return pairObservations[pair][first];
    }

    /// @notice Registra una observación si en el período actual todavía no hay una.
    /// @dev Idempotente dentro de un período: llamarla muchas veces no cuesta escrituras.
    function update(address tokenA, address tokenB) external {
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();
        Observation[] storage obs = pairObservations[pair];
        // Inicialización perezosa del buffer.
        for (uint256 i = obs.length; i < granularity; i++) {
            obs.push();
        }
        uint8 idx = observationIndexOf(block.timestamp);
        Observation storage o = obs[idx];
        uint256 elapsed = block.timestamp - o.timestamp;
        if (elapsed > periodSize) {
            (uint256 c0, uint256 c1,) = OracleLibrary.currentCumulativePrices(pair);
            o.timestamp = uint32(block.timestamp);
            o.price0Cumulative = c0;
            o.price1Cumulative = c1;
            emit Observed(pair, idx, uint32(block.timestamp));
        }
    }

    /// @notice Precio TWAP de la ventana: cuánto `tokenOut` valen `amountIn` de `tokenIn`.
    /// @dev Revierte si falta la observación histórica (keeper no actualizó a tiempo): es
    ///      preferible fallar que devolver un precio sobre una ventana incorrecta.
    function consult(address tokenIn, uint256 amountIn, address tokenOut) external view returns (uint256) {
        address pair = factory.getPair(tokenIn, tokenOut);
        if (pair == address(0)) revert PairNotFound();
        if (pairObservations[pair].length != granularity) revert MissingHistoricalObservation();
        Observation storage first = _firstObservationInWindow(pair);
        uint256 timeElapsed = block.timestamp - first.timestamp;
        if (first.timestamp == 0 || timeElapsed > windowSize) revert MissingHistoricalObservation();
        // No puede ser mucho menor a la ventana: si lo es, hubo un error de configuración.
        if (timeElapsed < windowSize - periodSize * 2) revert UnexpectedTimeElapsed();

        (uint256 c0, uint256 c1,) = OracleLibrary.currentCumulativePrices(pair);
        (address token0,) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        if (tokenIn == token0) {
            return OracleLibrary.computeAmountOut(first.price0Cumulative, c0, uint32(timeElapsed), amountIn);
        }
        return OracleLibrary.computeAmountOut(first.price1Cumulative, c1, uint32(timeElapsed), amountIn);
    }
}
