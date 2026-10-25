// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PaymentStream — pagos continuos por segundo (estilo Sablier)
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #99
/// @notice Un emisor deposita `deposit` tokens que se "liberan" linealmente
///         entre `startTime` y `stopTime`. El receptor puede retirar en
///         cualquier momento lo devengado; el emisor o el receptor pueden
///         cancelar y el saldo se reparte de forma justa al instante.
/// @dev Matemática:
///   devengado(t) = deposit × (min(t, stop) − start) / (stop − start)
///   disponibleReceptor = devengado − retirado
///   restanteEmisor     = deposit − devengado
///   Multiplicamos antes de dividir; el redondeo hacia abajo favorece al
///   emisor y el último segundo libera el total exacto (sin polvo atrapado).
///   No se ejecuta nada "cada segundo": el saldo se CALCULA al consultarlo.
contract PaymentStream is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidParams();
    error NotParty();
    error NotRecipient();
    error StreamNotFound(uint256 id);
    error NothingToWithdraw();

    event StreamCreated(
        uint256 indexed id, address indexed sender, address indexed recipient, address token, uint256 deposit, uint64 start, uint64 stop
    );
    event Withdrawn(uint256 indexed id, address indexed recipient, uint256 amount);
    event Cancelled(uint256 indexed id, uint256 toRecipient, uint256 toSender);

    struct Stream {
        address sender;     // quien paga
        address recipient;  // quien cobra
        IERC20 token;
        uint128 deposit;    // total a transmitir
        uint128 withdrawn;  // ya retirado por el receptor
        uint64 startTime;
        uint64 stopTime;
        bool active;
    }

    mapping(uint256 => Stream) public streams;
    uint256 public nextStreamId = 1;

    /// @notice Crear un stream depositando los tokens por adelantado.
    /// @dev Requiere `approve(this, deposit)` previo del emisor.
    function createStream(address recipient, IERC20 token, uint128 deposit, uint64 startTime, uint64 stopTime)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (
            recipient == address(0) || recipient == msg.sender || recipient == address(this) || deposit == 0
                || startTime < block.timestamp || stopTime <= startTime
        ) revert InvalidParams();
        id = nextStreamId++;
        streams[id] = Stream(msg.sender, recipient, token, deposit, 0, startTime, stopTime, true);
        token.safeTransferFrom(msg.sender, address(this), deposit);
        emit StreamCreated(id, msg.sender, recipient, address(token), deposit, startTime, stopTime);
    }

    /// @notice Tokens devengados hasta ahora (incluye lo ya retirado).
    function streamed(uint256 id) public view returns (uint256) {
        Stream storage s = _get(id);
        if (block.timestamp <= s.startTime) return 0;
        if (block.timestamp >= s.stopTime) return s.deposit;
        return (uint256(s.deposit) * (block.timestamp - s.startTime)) / (s.stopTime - s.startTime);
    }

    /// @notice Tasa nominal por segundo (informativa).
    function ratePerSecond(uint256 id) external view returns (uint256) {
        Stream storage s = _get(id);
        return s.deposit / (s.stopTime - s.startTime);
    }

    /// @notice Lo que el receptor puede retirar ya.
    function withdrawable(uint256 id) public view returns (uint256) {
        return streamed(id) - _get(id).withdrawn;
    }

    /// @notice El receptor retira (todo o parte de) lo devengado.
    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        Stream storage s = _get(id);
        if (msg.sender != s.recipient) revert NotRecipient();
        uint256 avail = withdrawable(id);
        if (amount == 0 || amount > avail) revert NothingToWithdraw();
        s.withdrawn += uint128(amount);
        emit Withdrawn(id, s.recipient, amount);
        s.token.safeTransfer(s.recipient, amount);
    }

    /// @notice Cancelación: el receptor cobra lo devengado y el emisor recupera el resto.
    function cancel(uint256 id) external nonReentrant {
        Stream storage s = _get(id);
        if (msg.sender != s.sender && msg.sender != s.recipient) revert NotParty();
        uint256 st = streamed(id);
        uint256 toRecipient = st - s.withdrawn;
        uint256 toSender = s.deposit - st;
        s.active = false; // efecto antes de transferir
        emit Cancelled(id, toRecipient, toSender);
        if (toRecipient > 0) s.token.safeTransfer(s.recipient, toRecipient);
        if (toSender > 0) s.token.safeTransfer(s.sender, toSender);
    }

    function _get(uint256 id) internal view returns (Stream storage s) {
        s = streams[id];
        if (!s.active) revert StreamNotFound(id);
    }
}
