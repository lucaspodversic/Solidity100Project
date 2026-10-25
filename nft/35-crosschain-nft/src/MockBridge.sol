// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockBridge — simula mensajería cross-chain (lock & mint / burn & unlock)
/// @author Proyecto 35
/// @notice En producción sería LayerZero / CCIP / Axelar. Acá el "relayer" es quien
///         llama `deliver` con el mismo payload. Cobramos un fee de gas simulado.
contract MockBridge {
    /// @notice Fee fijo (simulado) cobrado al enviar un mensaje.
    uint256 public immutable fee;
    address public immutable relayer;
    /// @notice Nonce por remitente para evitar replay del mismo mensaje.
    mapping(address => uint256) public nonces;
    /// @notice Mensajes ya entregados (hash del payload).
    mapping(bytes32 => bool) public delivered;

    event Sent(uint256 indexed dstChainId, address indexed from, bytes payload, uint256 nonce, uint256 feePaid);
    event Delivered(uint256 indexed srcChainId, bytes32 indexed msgHash, address target, bytes payload);

    error BadFee();
    error OnlyRelayer();
    error AlreadyDelivered();
    error CallFail();

    constructor(uint256 fee_, address relayer_) {
        fee = fee_;
        relayer = relayer_;
    }

    /// @notice Envía un mensaje a otra "cadena" pagando el fee.
    function send(uint256 dstChainId, bytes calldata payload) external payable returns (uint256 nonce) {
        if (msg.value < fee) revert BadFee();
        nonce = nonces[msg.sender]++;
        emit Sent(dstChainId, msg.sender, payload, nonce, msg.value);
        // El fee se queda en el bridge (tesorería del relayer).
    }

    /// @notice El relayer entrega el mensaje al contrato destino en la otra chain.
    /// @dev En un bridge real, la verificación sería con light client / oracle / DVN.
    function deliver(uint256 srcChainId, address target, bytes calldata payload) external {
        if (msg.sender != relayer) revert OnlyRelayer();
        bytes32 h = keccak256(abi.encode(srcChainId, target, payload));
        if (delivered[h]) revert AlreadyDelivered();
        delivered[h] = true;
        (bool ok,) = target.call(payload);
        if (!ok) revert CallFail();
        emit Delivered(srcChainId, h, target, payload);
    }
}
