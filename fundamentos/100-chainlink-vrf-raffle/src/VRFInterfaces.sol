// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Interfaces mínimas estilo Chainlink VRF v2.5
/// @notice Reproducimos SOLO lo necesario para no depender del paquete de
///         Chainlink en este ejemplo. En producción importá
///         VRFConsumerBaseV2Plus.sol del paquete npm "chainlink contracts" (v0.8/vrf/dev)
///         y `VRFV2PlusClient` (la firma de `requestRandomWords` usa un struct).
/// @dev Flujo VRF (Verifiable Random Function):
///   1. El consumidor pide N números con `requestRandomWords` => requestId.
///   2. Un nodo Chainlink genera el número + una PRUEBA criptográfica.
///   3. El Coordinator verifica la prueba on-chain y llama a
///      `rawFulfillRandomWords` del consumidor. Nadie (ni el nodo, ni el
///      minero) puede elegir el resultado sin invalidar la prueba.
interface IVRFCoordinatorMinimal {
    function requestRandomWords(
        bytes32 keyHash,
        uint256 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}

/// @title VRFConsumerBaseMinimal — base para recibir números aleatorios
/// @notice Solo el Coordinator puede entregar la respuesta (evita que
///         cualquiera "inyecte" un número elegido).
abstract contract VRFConsumerBaseMinimal {
    error OnlyCoordinatorCanFulfill(address have, address want);

    address internal immutable vrfCoordinator;

    constructor(address coordinator) {
        vrfCoordinator = coordinator;
    }

    /// @dev Lógica del consumidor. NO debe revertir (Chainlink no reintenta).
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal virtual;

    /// @notice Punto de entrada que invoca el Coordinator.
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != vrfCoordinator) revert OnlyCoordinatorCanFulfill(msg.sender, vrfCoordinator);
        fulfillRandomWords(requestId, randomWords);
    }
}
