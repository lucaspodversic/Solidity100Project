// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseMinimal, IVRFCoordinatorMinimal} from "./VRFInterfaces.sol";

/// @title Raffle — rifa descentralizada con aleatoriedad verificable (VRF)
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #100
/// @notice Ciclo de vida:
///   OPEN ──(pasa el intervalo + hay jugadores: requestWinner)──▶ CALCULATING
///   CALCULATING ──(Coordinator entrega el número)──▶ paga al ganador ──▶ OPEN
/// @dev Diferencia clave con la lotería #78: el número NO lo decide el
///      validador sino el oráculo VRF con prueba verificable. Mientras se
///      espera la respuesta, la rifa queda en CALCULATING y no acepta
///      jugadores (así nadie entra conociendo ya el resultado pendiente).
///      `requestWinner` es público (compatible con Chainlink Automation).
contract Raffle is VRFConsumerBaseMinimal {
    enum RaffleState { OPEN, CALCULATING }

    error WrongEntranceFee(uint256 enviado, uint256 requerido);
    error RaffleNotOpen();
    error UpkeepNotNeeded(uint256 balance, uint256 players, RaffleState state);
    error UnexpectedRequest(uint256 requestId);
    error TransferFailed();

    event RaffleEntered(address indexed player);
    event WinnerRequested(uint256 indexed requestId);
    event WinnerPicked(address indexed winner, uint256 prize);

    uint256 public immutable entranceFee;
    uint256 public immutable interval;
    bytes32 public immutable keyHash;        // "carril de gas" de Chainlink
    uint256 public immutable subscriptionId; // suscripción que paga el VRF
    uint32 public immutable callbackGasLimit;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant NUM_WORDS = 1;

    address payable[] private _players;
    uint256 public lastTimestamp;
    address public recentWinner;
    RaffleState public state;
    uint256 public pendingRequestId;

    constructor(
        address coordinator,
        uint256 entranceFee_,
        uint256 interval_,
        bytes32 keyHash_,
        uint256 subId_,
        uint32 callbackGasLimit_
    ) VRFConsumerBaseMinimal(coordinator) {
        entranceFee = entranceFee_;
        interval = interval_;
        keyHash = keyHash_;
        subscriptionId = subId_;
        callbackGasLimit = callbackGasLimit_;
        lastTimestamp = block.timestamp;
    }

    /// @notice Comprar una entrada.
    function enter() external payable {
        if (msg.value != entranceFee) revert WrongEntranceFee(msg.value, entranceFee);
        if (state != RaffleState.OPEN) revert RaffleNotOpen();
        _players.push(payable(msg.sender));
        emit RaffleEntered(msg.sender);
    }

    /// @notice ¿Corresponde sortear? (formato checkUpkeep de Automation)
    function checkUpkeep() public view returns (bool) {
        return state == RaffleState.OPEN && block.timestamp - lastTimestamp >= interval && _players.length > 0;
    }

    /// @notice Pide el número aleatorio al Coordinator.
    function requestWinner() external returns (uint256 requestId) {
        if (!checkUpkeep()) revert UpkeepNotNeeded(address(this).balance, _players.length, state);
        state = RaffleState.CALCULATING;
        requestId = IVRFCoordinatorMinimal(vrfCoordinator).requestRandomWords(
            keyHash, subscriptionId, REQUEST_CONFIRMATIONS, callbackGasLimit, NUM_WORDS
        );
        pendingRequestId = requestId;
        emit WinnerRequested(requestId);
    }

    /// @dev Callback del VRF: elige ganador, reinicia y paga.
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        if (requestId != pendingRequestId) revert UnexpectedRequest(requestId);
        address payable winner = _players[randomWords[0] % _players.length];
        uint256 prize = address(this).balance;
        recentWinner = winner;
        delete _players;
        state = RaffleState.OPEN;
        lastTimestamp = block.timestamp;
        pendingRequestId = 0;
        emit WinnerPicked(winner, prize);
        (bool ok,) = winner.call{value: prize}("");
        if (!ok) revert TransferFailed();
    }

    function playersCount() external view returns (uint256) {
        return _players.length;
    }

    function playerAt(uint256 i) external view returns (address) {
        return _players[i];
    }
}
