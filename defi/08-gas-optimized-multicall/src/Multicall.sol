// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Multicall — agrega múltiples llamadas en una sola transacción (estilo Multicall3)
/// @notice Útil para leer muchos datos en un solo RPC (balances, reservas, precios) o para
///         ejecutar varias acciones juntas. Es **sin estado** y no tiene owner.
/// @dev Optimizaciones de gas:
///      - argumentos `calldata` (sin copiar a memoria);
///      - bucles `unchecked` con `++i`;
///      - longitud cacheada;
///      - structs mínimos.
///      ADVERTENCIA: en las llamadas, `msg.sender` es ESTE contrato y no el usuario. Nunca
///      apruebes tokens a un Multicall genérico: cualquiera podría usar esa aprobación.
contract Multicall {
    struct Call {
        address target;
        bytes callData;
    }

    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Call3Value {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    error CallFailed(uint256 index, bytes reason);
    error ValueMismatch(uint256 sent, uint256 expected);

    /// @notice Ejecuta todas las llamadas; si alguna falla, revierte todo.
    function aggregate(Call[] calldata calls) external returns (uint256 blockNumber, bytes[] memory returnData) {
        blockNumber = block.number;
        uint256 len = calls.length;
        returnData = new bytes[](len);
        for (uint256 i; i < len;) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].callData);
            if (!ok) revert CallFailed(i, ret);
            returnData[i] = ret;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Como aggregate, pero `requireSuccess=false` permite fallas individuales.
    function tryAggregate(bool requireSuccess, Call[] calldata calls) external returns (Result[] memory results) {
        uint256 len = calls.length;
        results = new Result[](len);
        for (uint256 i; i < len;) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].callData);
            if (requireSuccess && !ok) revert CallFailed(i, ret);
            results[i] = Result(ok, ret);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Cada llamada define si puede fallar.
    function aggregate3(Call3[] calldata calls) external returns (Result[] memory results) {
        uint256 len = calls.length;
        results = new Result[](len);
        for (uint256 i; i < len;) {
            Call3 calldata c = calls[i];
            (bool ok, bytes memory ret) = c.target.call(c.callData);
            if (!ok && !c.allowFailure) revert CallFailed(i, ret);
            results[i] = Result(ok, ret);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Llamadas con ETH. `msg.value` debe ser EXACTAMENTE la suma de los valores.
    /// @dev Si no se verificara, el excedente quedaría atrapado aquí y el próximo usuario
    ///      podría gastarlo. Si una llamada con valor falla y `allowFailure`, el ETH de esa
    ///      llamada no se envió: lo devolvemos al final para no dejar saldo en el contrato.
    function aggregate3Value(Call3Value[] calldata calls) external payable returns (Result[] memory results) {
        uint256 len = calls.length;
        results = new Result[](len);
        uint256 total;
        uint256 refund;
        for (uint256 i; i < len;) {
            Call3Value calldata c = calls[i];
            total += c.value;
            (bool ok, bytes memory ret) = c.target.call{value: c.value}(c.callData);
            if (!ok) {
                if (!c.allowFailure) revert CallFailed(i, ret);
                refund += c.value;
            }
            results[i] = Result(ok, ret);
            unchecked {
                ++i;
            }
        }
        if (msg.value != total) revert ValueMismatch(msg.value, total);
        if (refund > 0) {
            (bool s,) = msg.sender.call{value: refund}("");
            require(s, "refund");
        }
    }

    // ---- utilidades de lectura (para agregarlas como llamadas al propio contrato) ----

    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function getCurrentBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function getEthBalance(address a) external view returns (uint256) {
        return a.balance;
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }
}
