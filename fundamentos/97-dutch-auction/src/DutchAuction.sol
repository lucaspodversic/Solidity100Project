// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title DemoNFT — NFT mínimo para subastar
contract DemoNFT is ERC721 {
    constructor() ERC721("Demo NFT", "DNFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @title DutchAuction — subasta holandesa (precio descendente) de un NFT
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #97
/// @notice El precio arranca alto y baja linealmente cada segundo hasta un
///         piso. El primero que acepta el precio actual se lleva el NFT.
///         precio(t) = startPrice - (startPrice - floorPrice) * min(t, D) / D
/// @dev Ventajas frente a la inglesa: una sola transacción, sin pujas ni
///      reembolsos múltiples, descubrimiento de precio rápido. Riesgos:
///   - El comprador envía ETH de más (el precio baja entre que firma y se
///     mina): devolvemos el excedente.
///   - MEV: un bot puede comprar apenas el precio cruza su valoración.
///   - El vendedor debe aprobar el NFT al contrato antes de `start`.
contract DutchAuction {
    error NotSeller();
    error AlreadyStarted();
    error NotStarted();
    error AuctionOver();
    error InsufficientPayment(uint256 enviado, uint256 precio);
    error InvalidParams();
    error TransferFailed();

    event Started(uint256 startAt);
    event Bought(address indexed buyer, uint256 price);

    IERC721 public immutable nft;
    uint256 public immutable nftId;
    address payable public immutable seller;
    uint256 public immutable startPrice;
    uint256 public immutable floorPrice;
    uint256 public immutable duration;

    uint256 public startAt;
    bool public sold;

    constructor(IERC721 nft_, uint256 nftId_, uint256 startPrice_, uint256 floorPrice_, uint256 duration_) {
        if (startPrice_ < floorPrice_ || duration_ == 0) revert InvalidParams();
        nft = nft_;
        nftId = nftId_;
        seller = payable(msg.sender);
        startPrice = startPrice_;
        floorPrice = floorPrice_;
        duration = duration_;
    }

    /// @notice El vendedor deposita el NFT y arranca el reloj.
    function start() external {
        if (msg.sender != seller) revert NotSeller();
        if (startAt != 0) revert AlreadyStarted();
        startAt = block.timestamp;
        // Custodia: el NFT queda en el contrato hasta la venta.
        nft.transferFrom(seller, address(this), nftId);
        emit Started(startAt);
    }

    /// @notice Precio actual (decrece linealmente y se clava en el piso).
    function currentPrice() public view returns (uint256) {
        if (startAt == 0) return startPrice;
        uint256 elapsed = block.timestamp - startAt;
        if (elapsed >= duration) return floorPrice;
        // Multiplicar antes de dividir para no perder precisión.
        return startPrice - ((startPrice - floorPrice) * elapsed) / duration;
    }

    /// @notice Comprar al precio actual; el excedente se devuelve.
    function buy() external payable {
        if (startAt == 0) revert NotStarted();
        if (sold) revert AuctionOver();
        uint256 price = currentPrice();
        if (msg.value < price) revert InsufficientPayment(msg.value, price);
        sold = true;
        emit Bought(msg.sender, price);

        nft.transferFrom(address(this), msg.sender, nftId);
        (bool ok,) = seller.call{value: price}("");
        if (!ok) revert TransferFailed();
        uint256 refund = msg.value - price;
        if (refund > 0) {
            (ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
    }
}
