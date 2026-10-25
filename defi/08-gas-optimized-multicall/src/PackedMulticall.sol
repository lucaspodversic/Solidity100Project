// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PackedMulticall — multicall con codificación compacta (ahorro de calldata)
/// @notice En L2s (rollups) la mayor parte del costo es el calldata que se publica en L1.
///         La codificación ABI rellena todo a 32 bytes; acá usamos un formato empaquetado:
///
///         entrada: repetido [ target (20 bytes) | len (2 bytes) | data (len bytes) ]
///         salida : repetido [ len (2 bytes) | returnData (len bytes) ]
///
///         Se invoca enviando los bytes directamente (sin selector) → cae en `fallback`.
/// @dev Si cualquier llamada falla, revierte todo con el índice. No acepta ETH.
///      El contrato NO tiene otras funciones externas: así ningún input empaquetado puede
///      coincidir por accidente con un selector (los helpers están en `PackedCodec`).
contract PackedMulticall {
    error CallFailed(uint256 index, bytes reason);
    error Malformed();

    fallback(bytes calldata input) external returns (bytes memory out) {
        uint256 i;
        uint256 n;
        uint256 total = input.length;
        while (i < total) {
            if (i + 22 > total) revert Malformed();
            address target = address(bytes20(input[i:i + 20]));
            uint256 len = uint16(bytes2(input[i + 20:i + 22]));
            uint256 start = i + 22;
            if (start + len > total) revert Malformed();
            (bool ok, bytes memory ret) = target.call(input[start:start + len]);
            if (!ok) revert CallFailed(n, ret);
            if (ret.length > type(uint16).max) revert Malformed();
            out = bytes.concat(out, bytes2(uint16(ret.length)), ret);
            unchecked {
                i = start + len;
                ++n;
            }
        }
    }
}

/// @title PackedCodec — helpers para codificar/decodificar el formato de PackedMulticall
/// @notice Contrato separado a propósito (ver nota de selectores arriba).
contract PackedCodec {
    /// @notice Helper para construir la entrada empaquetada (off-chain o en tests).
    function encode(address[] calldata targets, bytes[] calldata datas) external pure returns (bytes memory out) {
        require(targets.length == datas.length, "len");
        for (uint256 i; i < targets.length; i++) {
            require(datas[i].length <= type(uint16).max, "data");
            out = bytes.concat(out, bytes20(targets[i]), bytes2(uint16(datas[i].length)), datas[i]);
        }
    }

    /// @notice Decodifica la salida empaquetada en un arreglo.
    function decode(bytes calldata packed) external pure returns (bytes[] memory results) {
        // primera pasada: contar
        uint256 count;
        uint256 i;
        while (i < packed.length) {
            i += 2 + uint16(bytes2(packed[i:i + 2]));
            count++;
        }
        results = new bytes[](count);
        i = 0;
        for (uint256 k; k < count; k++) {
            uint256 len = uint16(bytes2(packed[i:i + 2]));
            results[k] = packed[i + 2:i + 2 + len];
            i += 2 + len;
        }
    }
}
