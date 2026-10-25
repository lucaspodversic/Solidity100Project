// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/// @title GaslessToken — ERC20 compatible con meta-transacciones (EIP-2771)
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #96
/// @notice Flujo de una meta-transacción:
///   1. El usuario (sin ETH) firma OFF-CHAIN un `ForwardRequest` EIP-712
///      ("quiero llamar a GaslessToken.transfer(bob, 10)").
///   2. Un *relayer* envía esa firma al `ERC2771Forwarder` y paga el gas.
///   3. El forwarder verifica firma, nonce y deadline, y llama al token
///      agregando 20 bytes al final del calldata: la dirección del firmante.
///   4. El token, al confiar en ese forwarder, usa `_msgSender()` que lee
///      esos 20 bytes => la acción se atribuye al usuario, no al relayer.
/// @dev SEGURIDAD:
///   - Usar SIEMPRE `_msgSender()` en vez de `msg.sender` en todo el contrato.
///   - Confiar solo en un forwarder auditado (OZ ERC2771Forwarder). Un
///     forwarder malicioso podría hacerse pasar por cualquier usuario.
///   - No combinar ERC-2771 con `Multicall` sin las protecciones de OZ ≥4.9.3
///     (vulnerabilidad de spoofing de dirección de diciembre 2023).
contract GaslessToken is ERC20, ERC2771Context {
    /// @param forwarder Dirección del forwarder de confianza (inmutable).
    constructor(address forwarder) ERC20("Gasless Token", "GAS") ERC2771Context(forwarder) {
        _mint(msg.sender, 1_000_000 ether);
    }

    /// @notice Faucet de ejemplo: muestra que `_msgSender()` es el firmante real.
    function faucet() external {
        _mint(_msgSender(), 100 ether);
    }

    // --- Resolución de herencia diamante: Context (de ERC20) vs ERC2771Context ---

    /// @dev Si la llamada viene del forwarder, devuelve los últimos 20 bytes del calldata.
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    /// @dev Calldata sin el sufijo de 20 bytes del forwarder.
    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @dev Longitud del sufijo (20) usada por OZ internamente.
    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}
