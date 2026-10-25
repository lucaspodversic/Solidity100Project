// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title NFTMarketplace — listados ERC721 con comisión y protección reentrancy
/// @author Proyecto 31
/// @notice Marketplace escrowless: el NFT se transfiere al contrato al listar y vuelve
///         al comprador o al vendedor al comprar/cancelar. Comisión en basis points.
/// @dev Usa ReentrancyGuard + patrón CEI. El pago al vendedor se hace con `call` y
///      se verifica; si falla, la compra revierte (no se pierde el NFT).
contract NFTMarketplace is ReentrancyGuard, Ownable {
    /// @notice Listado activo de un NFT.
    struct Listing {
        address seller;   // dueño original
        address nft;      // dirección del ERC721
        uint256 tokenId;  // id del token
        uint256 price;    // precio en wei
        bool active;      // true mientras esté a la venta
    }

    /// @notice Comisión del marketplace en basis points (100 = 1%).
    uint256 public feeBps;
    /// @notice Destino de las comisiones.
    address public feeRecipient;
    /// @notice Contador de listados (ids arrancan en 1).
    uint256 public nextListingId = 1;
    /// @notice Listados por id.
    mapping(uint256 => Listing) public listings;
    /// @notice Id de listado activo por (nft, tokenId); 0 = ninguno.
    mapping(address => mapping(uint256 => uint256)) public listingOf;

    event Listed(uint256 indexed id, address indexed seller, address indexed nft, uint256 tokenId, uint256 price);
    event Bought(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee);
    event Cancelled(uint256 indexed id);
    event FeeUpdated(uint256 feeBps, address recipient);

    error ZeroPrice();
    error NotOwner();
    error NotActive();
    error WrongPayment(uint256 expected, uint256 sent);
    error TransferFailed();
    error FeeTooHigh();

    /// @param feeBps_ Comisión inicial (máx 1000 = 10%).
    /// @param feeRecipient_ Destino de comisiones.
    constructor(uint256 feeBps_, address feeRecipient_) Ownable(msg.sender) {
        if (feeBps_ > 1000) revert FeeTooHigh();
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
    }

    /// @notice Lista un NFT a un precio fijo. El NFT se custodia en el marketplace.
    /// @dev El caller debe haber aprobado el marketplace (`setApprovalForAll` o `approve`).
    function list(address nft, uint256 tokenId, uint256 price) external nonReentrant returns (uint256 id) {
        if (price == 0) revert ZeroPrice();
        if (IERC721(nft).ownerOf(tokenId) != msg.sender) revert NotOwner();
        // EFFECTS primero: reservamos el id y marcamos el mapping.
        id = nextListingId++;
        listings[id] = Listing({seller: msg.sender, nft: nft, tokenId: tokenId, price: price, active: true});
        listingOf[nft][tokenId] = id;
        // INTERACTIONS: transferimos el NFT al escrow del contrato.
        IERC721(nft).transferFrom(msg.sender, address(this), tokenId);
        emit Listed(id, msg.sender, nft, tokenId, price);
    }

    /// @notice Compra un listado activo pagando exactamente `price`.
    function buy(uint256 id) external payable nonReentrant {
        Listing storage L = listings[id];
        if (!L.active) revert NotActive();
        if (msg.value != L.price) revert WrongPayment(L.price, msg.value);

        // EFFECTS: desactivamos antes de pagar / transferir (CEI).
        L.active = false;
        delete listingOf[L.nft][L.tokenId];

        uint256 fee = (L.price * feeBps) / 10_000;
        uint256 toSeller = L.price - fee;

        // INTERACTIONS: primero el NFT al comprador (sin callback si es EOA),
        // luego pagos. Si alguno falla, toda la tx revierte.
        IERC721(L.nft).transferFrom(address(this), msg.sender, L.tokenId);
        _pay(L.seller, toSeller);
        if (fee > 0) _pay(feeRecipient, fee);

        emit Bought(id, msg.sender, L.price, fee);
    }

    /// @notice Cancela un listado y recupera el NFT (solo el vendedor).
    function cancel(uint256 id) external nonReentrant {
        Listing storage L = listings[id];
        if (!L.active) revert NotActive();
        if (L.seller != msg.sender) revert NotOwner();
        L.active = false;
        delete listingOf[L.nft][L.tokenId];
        IERC721(L.nft).transferFrom(address(this), msg.sender, L.tokenId);
        emit Cancelled(id);
    }

    /// @notice Actualiza comisión y destinatario (máx 10%).
    function setFee(uint256 feeBps_, address recipient) external onlyOwner {
        if (feeBps_ > 1000) revert FeeTooHigh();
        feeBps = feeBps_;
        feeRecipient = recipient;
        emit FeeUpdated(feeBps_, recipient);
    }

    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
