// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Receptor de mensajes cross-chain (análogo a CCIPReceiver).
interface IMessageReceiver {
    function receiveMessage(bytes32 id, uint64 sourceChain, address sourceSender, bytes calldata payload) external;
}

/// @title MockRouter — Simula una red de mensajería cross-chain (CCIP / LayerZero / Hyperlane)
/// @notice En un solo EVM de test simulamos varias "cadenas": cada TokenPool tiene un
///         `chainSelector`. `send` encola el mensaje; un "relayer" (cualquiera, en el mock)
///         lo entrega con `deliver`, simulando la latencia y la finalidad de la cadena origen.
/// @dev En producción el router de destino lo opera la red de mensajería (DON de CCIP) y
///      verifica la prueba o atestación del mensaje. Acá la confianza está en este contrato.
contract MockRouter {
    struct Message {
        uint64 sourceChain;
        uint64 destChain;
        address sender;
        address receiver;
        bytes payload;
        bool delivered;
    }

    mapping(bytes32 => Message) public messages;
    uint256 public nonce;

    event MessageSent(bytes32 indexed id, uint64 sourceChain, uint64 destChain, address receiver);
    event MessageDelivered(bytes32 indexed id);

    error AlreadyDelivered();
    error UnknownMessage();

    /// @notice Encola un mensaje. `sourceChain` lo declara el pool emisor (en el mock confiamos en él).
    function send(uint64 sourceChain, uint64 destChain, address receiver, bytes calldata payload)
        external
        returns (bytes32 id)
    {
        id = keccak256(abi.encode(sourceChain, destChain, msg.sender, receiver, payload, nonce++));
        messages[id] = Message(sourceChain, destChain, msg.sender, receiver, payload, false);
        emit MessageSent(id, sourceChain, destChain, receiver);
    }

    /// @notice Entrega un mensaje una única vez.
    function deliver(bytes32 id) external {
        Message storage m = messages[id];
        if (m.receiver == address(0)) revert UnknownMessage();
        if (m.delivered) revert AlreadyDelivered();
        m.delivered = true;
        IMessageReceiver(m.receiver).receiveMessage(id, m.sourceChain, m.sender, m.payload);
        emit MessageDelivered(id);
    }
}
