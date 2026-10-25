// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SimpleLottery — lotería con aleatoriedad PSEUDOaleatoria
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #78
/// @notice Los jugadores compran boletos a precio fijo. Pasado el plazo, el
///         organizador sortea un ganador que se lleva el pozo.
/// @dev ⚠️ ADVERTENCIA DE SEGURIDAD — LEER ANTES DE USAR EN PRODUCCIÓN ⚠️
///      La "aleatoriedad" se obtiene con `keccak256(block.prevrandao, ...)`.
///      Esto NO es aleatorio en un sentido criptográfico:
///      - `block.prevrandao` (antes `difficulty`) es conocido por el
///        proponente del bloque, que puede decidir NO publicar un bloque si el
///        resultado no le conviene (sesgo de "último revelador").
///      - `block.timestamp` y `blockhash` son manipulables o predecibles.
///      - Cualquier contrato puede calcular el mismo valor en la misma
///        transacción y solo participar si gana.
///      Para dinero real usá un oráculo de aleatoriedad verificable
///      (Chainlink VRF, ver proyecto #100) o un esquema commit-reveal.
contract SimpleLottery {
    error NotOrganizer();
    error WrongTicketPrice(uint256 enviado, uint256 requerido);
    error LotteryClosed();
    error LotteryStillOpen();
    error NoPlayers();
    error TransferFailed();

    event TicketBought(address indexed player, uint256 indexed round);
    event WinnerPicked(address indexed winner, uint256 prize, uint256 indexed round);

    /// @notice Quien despliega y dispara el sorteo.
    address public immutable organizer;
    /// @notice Precio de cada boleto en wei.
    uint256 public immutable ticketPrice;
    /// @notice Duración de cada ronda en segundos.
    uint256 public immutable roundDuration;

    /// @notice Lista de boletos (una dirección puede aparecer varias veces).
    address[] public players;
    /// @notice Fin de la ronda actual.
    uint256 public roundEnd;
    /// @notice Número de ronda (arranca en 1).
    uint256 public round = 1;
    /// @notice Último ganador (útil para frontends y tests).
    address public lastWinner;

    constructor(uint256 ticketPrice_, uint256 roundDuration_) {
        organizer = msg.sender;
        ticketPrice = ticketPrice_;
        roundDuration = roundDuration_;
        roundEnd = block.timestamp + roundDuration_;
    }

    /// @notice Comprar un boleto pagando exactamente `ticketPrice`.
    function enter() external payable {
        if (block.timestamp >= roundEnd) revert LotteryClosed();
        if (msg.value != ticketPrice) revert WrongTicketPrice(msg.value, ticketPrice);
        players.push(msg.sender);
        emit TicketBought(msg.sender, round);
    }

    /// @notice Cantidad de boletos vendidos en la ronda.
    function playersCount() external view returns (uint256) {
        return players.length;
    }

    /// @notice Número pseudoaleatorio. **Predecible y manipulable** (ver arriba).
    /// @dev `prevrandao` es la salida RANDAO de la beacon chain post-Merge.
    function _pseudoRandom() internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.prevrandao, block.timestamp, players.length, round)));
    }

    /// @notice Sortea el ganador, le paga el pozo y abre una ronda nueva.
    function pickWinner() external {
        if (msg.sender != organizer) revert NotOrganizer();
        if (block.timestamp < roundEnd) revert LotteryStillOpen();
        uint256 n = players.length;
        if (n == 0) revert NoPlayers();

        // Módulo para mapear el número a un índice válido. (El sesgo de módulo
        // es despreciable porque 2^256 >> n.)
        address winner = players[_pseudoRandom() % n];
        uint256 prize = address(this).balance;

        // EFFECTS: reiniciamos la ronda antes de pagar (CEI).
        emit WinnerPicked(winner, prize, round);
        lastWinner = winner;
        delete players; // borra la longitud; el gas depende de n (cuidado con listas enormes)
        round += 1;
        roundEnd = block.timestamp + roundDuration;

        // INTERACTIONS
        (bool ok,) = winner.call{value: prize}("");
        if (!ok) revert TransferFailed();
    }
}
