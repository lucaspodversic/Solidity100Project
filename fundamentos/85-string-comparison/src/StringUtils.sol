// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title StringUtils — comparación de strings en Solidity
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #85
/// @notice Solidity NO permite `a == b` entre `string`. Los strings son arrays
///         dinámicos de bytes; hay que compararlos contenido contra contenido.
/// @dev Tres técnicas:
///   1. `keccak256(bytes(a)) == keccak256(bytes(b))`: la más común y legible.
///   2. Comparar longitudes primero (atajo barato si difieren) y luego hash.
///   3. Bucle byte a byte (didáctico; más caro en strings largos).
///   ⚠️ Nunca uses `abi.encodePacked(a, b)` con dos strings dinámicos para
///   generar un identificador: ("ab","c") y ("a","bc") producen el mismo
///   empaquetado => colisión de hash. Usá `abi.encode` en ese caso.
library StringUtils {
    /// @notice Igualdad por hash keccak256 del contenido.
    function equal(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Igualdad con atajo por longitud (ahorra el hash si difieren).
    function equalFast(string memory a, string memory b) internal pure returns (bool) {
        return bytes(a).length == bytes(b).length && keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Igualdad byte a byte (didáctica).
    function equalLoop(string memory a, string memory b) internal pure returns (bool) {
        bytes memory ba = bytes(a);
        bytes memory bb = bytes(b);
        if (ba.length != bb.length) return false;
        for (uint256 i; i < ba.length; ++i) {
            if (ba[i] != bb[i]) return false;
        }
        return true;
    }

    /// @notice Comparación ignorando mayúsculas/minúsculas ASCII (A-Z).
    function equalIgnoreCase(string memory a, string memory b) internal pure returns (bool) {
        bytes memory ba = bytes(a);
        bytes memory bb = bytes(b);
        if (ba.length != bb.length) return false;
        for (uint256 i; i < ba.length; ++i) {
            if (_lower(ba[i]) != _lower(bb[i])) return false;
        }
        return true;
    }

    /// @dev Pasa un byte ASCII A-Z a minúscula sumando 32 ('A'=0x41 -> 'a'=0x61).
    function _lower(bytes1 c) private pure returns (bytes1) {
        if (c >= 0x41 && c <= 0x5A) return bytes1(uint8(c) + 32);
        return c;
    }
}

/// @title PasswordGame — uso práctico: comparar una respuesta contra un hash guardado
/// @notice Guardamos solo el hash de la respuesta (no el texto) y comparamos.
/// @dev ⚠️ El hash es público en cadena: respuestas cortas o comunes se pueden
///      adivinar por fuerza bruta offline. Es un ejemplo, no un secreto real.
contract PasswordGame {
    using StringUtils for string;

    /// @notice Hash keccak256 de la respuesta correcta.
    bytes32 public immutable answerHash;
    /// @notice Primer acertante.
    address public winner;

    error WrongAnswer();
    error AlreadySolved();

    constructor(bytes32 answerHash_) {
        answerHash = answerHash_;
    }

    /// @notice Intentar adivinar. Compara hash contra hash.
    function guess(string calldata answer) external {
        if (winner != address(0)) revert AlreadySolved();
        if (keccak256(bytes(answer)) != answerHash) revert WrongAnswer();
        winner = msg.sender;
    }

    /// @notice Expone la librería para pruebas/demostración.
    function compare(string memory a, string memory b) external pure returns (bool, bool, bool, bool) {
        return (a.equal(b), a.equalFast(b), a.equalLoop(b), a.equalIgnoreCase(b));
    }
}
