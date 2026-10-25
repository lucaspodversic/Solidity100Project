// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAdapter — interfaz de los módulos que el executor encadena
/// @notice Cada adapter se ejecuta vía DELEGATECALL en el contexto del executor (los tokens
///         están en el executor). Reglas para escribir un adapter:
///         1. NO usar storage (corrompería el del executor). Sólo immutables/constantes.
///         2. Recibir `prev` = salida del paso anterior (para encadenar montos).
///         3. Devolver la "salida" del paso (normalmente el monto de token obtenido).
interface IAdapter {
    function execute(bytes calldata data, uint256 prev) external payable returns (uint256 out);
}
