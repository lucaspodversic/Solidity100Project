// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CPAMMPair} from "./CPAMMPair.sol";

/// @title CPAMMFactory — Fábrica de pares x*y=k
/// @notice Despliega un único par por combinación de tokens usando CREATE2, de modo que la
///         dirección del par es determinística y calculable off-chain (útil para routers).
contract CPAMMFactory {
    /// @notice getPair[tokenA][tokenB] => par (registrado en ambos órdenes).
    mapping(address => mapping(address => address)) public getPair;
    /// @notice Lista de todos los pares creados.
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 index);

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();

    /// @notice Cantidad de pares creados.
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @notice Crea el par para (tokenA, tokenB). Revierte si ya existe.
    /// @dev Ordenamos los tokens para que (A,B) y (B,A) sean el mismo par.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (t0 == address(0)) revert ZeroAddress();
        if (getPair[t0][t1] != address(0)) revert PairExists();
        // El salt depende solo de los tokens => dirección predecible.
        bytes32 salt = keccak256(abi.encodePacked(t0, t1));
        pair = address(new CPAMMPair{salt: salt}());
        CPAMMPair(pair).initialize(t0, t1);
        getPair[t0][t1] = pair;
        getPair[t1][t0] = pair;
        allPairs.push(pair);
        emit PairCreated(t0, t1, pair, allPairs.length);
    }
}
