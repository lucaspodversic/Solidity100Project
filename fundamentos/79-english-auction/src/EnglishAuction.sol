// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EnglishAuction — subasta inglesa (precio ascendente) con anti-sniping
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #79
/// @notice El vendedor abre una subasta con precio de reserva. Cada puja debe
///         superar la mejor puja actual por un incremento mínimo. Si alguien
///         puja en los últimos `extensionWindow` segundos, el cierre se
///         extiende (evita el "sniping" de último segundo).
/// @dev Patrón **pull payments**: las pujas superadas NO se devuelven
///      automáticamente (eso permitiría a un contrato malicioso que rechace
///      ETH bloquear la subasta). Se acumulan en `pendingReturns` y cada
///      postor las retira con `withdraw()`.
contract EnglishAuction {
    error AuctionNotStarted();
    error AuctionEnded();
    error AuctionNotEnded();
    error AlreadyStarted();
    error AlreadySettled();
    error NotSeller();
    error BidTooLow(uint256 enviado, uint256 minimo);
    error NothingToWithdraw();
    error TransferFailed();

    event Started(uint256 endTime);
    event Bid(address indexed bidder, uint256 amount, uint256 endTime);
    event Withdrawn(address indexed bidder, uint256 amount);
    event Settled(address indexed winner, uint256 amount);

    /// @notice Vendedor que cobra la puja ganadora.
    address public immutable seller;
    /// @notice Precio mínimo para la primera puja.
    uint256 public immutable reservePrice;
    /// @notice Incremento mínimo sobre la mejor puja (en wei).
    uint256 public immutable minIncrement;
    /// @notice Duración inicial de la subasta (segundos).
    uint256 public immutable duration;
    /// @notice Ventana final en la que una puja extiende el cierre.
    uint256 public constant extensionWindow = 10 minutes;

    bool public started;
    bool public settled;
    uint256 public endTime;
    address public highestBidder;
    uint256 public highestBid;
    /// @notice ETH reembolsable a postores superados.
    mapping(address => uint256) public pendingReturns;

    constructor(uint256 reservePrice_, uint256 minIncrement_, uint256 duration_) {
        seller = msg.sender;
        reservePrice = reservePrice_;
        minIncrement = minIncrement_;
        duration = duration_;
    }

    /// @notice El vendedor inicia la subasta.
    function start() external {
        if (msg.sender != seller) revert NotSeller();
        if (started) revert AlreadyStarted();
        started = true;
        endTime = block.timestamp + duration;
        emit Started(endTime);
    }

    /// @notice Puja mínima aceptable en este momento.
    function minNextBid() public view returns (uint256) {
        return highestBid == 0 ? reservePrice : highestBid + minIncrement;
    }

    /// @notice Pujar enviando ETH.
    function bid() external payable {
        if (!started) revert AuctionNotStarted();
        if (block.timestamp >= endTime) revert AuctionEnded();
        uint256 min = minNextBid();
        if (msg.value < min) revert BidTooLow(msg.value, min);

        // El postor anterior pasa a tener saldo reclamable (pull).
        if (highestBidder != address(0)) {
            pendingReturns[highestBidder] += highestBid;
        }
        highestBidder = msg.sender;
        highestBid = msg.value;

        // Anti-sniping: si faltan menos de 10 min, extendemos el cierre.
        if (endTime - block.timestamp < extensionWindow) {
            endTime = block.timestamp + extensionWindow;
        }
        emit Bid(msg.sender, msg.value, endTime);
    }

    /// @notice Retirar pujas superadas.
    function withdraw() external {
        uint256 amount = pendingReturns[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingReturns[msg.sender] = 0; // efecto antes de interacción
        emit Withdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Cierra la subasta y paga al vendedor (cualquiera puede llamarla).
    function settle() external {
        if (!started) revert AuctionNotStarted();
        if (block.timestamp < endTime) revert AuctionNotEnded();
        if (settled) revert AlreadySettled();
        settled = true;
        emit Settled(highestBidder, highestBid);
        if (highestBid > 0) {
            (bool ok,) = seller.call{value: highestBid}("");
            if (!ok) revert TransferFailed();
        }
    }
}
