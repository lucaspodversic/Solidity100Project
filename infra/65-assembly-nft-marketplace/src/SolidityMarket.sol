// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title SolidityMarket — Marketplace de referencia en Solidity "normal"
/// @notice Misma lógica que `AsmMarket` pero escrita de forma idiomática y legible.
///         Sirve como línea base para comparar gas y como oráculo de correctitud
///         en los tests diferenciales.
contract SolidityMarket {
    /// @notice Listado (2 slots: seller y price separados, sin empaquetar).
    struct Listing {
        address seller;
        uint256 price;
    }

    uint256 public constant FEE_BPS = 250; // 2,5%
    address public immutable feeRecipient;
    uint256 public accruedFees;
    bool private locked;

    mapping(address => mapping(uint256 => Listing)) public listings;

    event Listed(address indexed nft, uint256 indexed id, address indexed seller, uint256 price);
    event Cancelled(address indexed nft, uint256 indexed id);
    event Sold(address indexed nft, uint256 indexed id, address indexed buyer, uint256 price);

    error NotOwner();
    error NotApproved();
    error ZeroPrice();
    error NotListed();
    error WrongPrice();
    error TransferFailed();
    error Reentrancy();

    constructor(address _feeRecipient) {
        feeRecipient = _feeRecipient;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    /// @notice Publica un NFT a la venta.
    function list(address nft, uint256 id, uint96 price) external {
        if (price == 0) revert ZeroPrice();
        if (IERC721(nft).ownerOf(id) != msg.sender) revert NotOwner();
        if (!IERC721(nft).isApprovedForAll(msg.sender, address(this)) && IERC721(nft).getApproved(id) != address(this)) {
            revert NotApproved();
        }
        listings[nft][id] = Listing(msg.sender, price);
        emit Listed(nft, id, msg.sender, price);
    }

    /// @notice Cancela un listado propio.
    function cancel(address nft, uint256 id) external {
        if (listings[nft][id].seller != msg.sender) revert NotOwner();
        delete listings[nft][id];
        emit Cancelled(nft, id);
    }

    /// @notice Compra un NFT pagando exactamente el precio.
    function buy(address nft, uint256 id) external payable nonReentrant {
        Listing memory l = listings[nft][id];
        if (l.seller == address(0)) revert NotListed();
        if (msg.value != l.price) revert WrongPrice();
        delete listings[nft][id];
        uint256 fee = (l.price * FEE_BPS) / 10_000;
        accruedFees += fee;
        IERC721(nft).transferFrom(l.seller, msg.sender, id);
        (bool ok,) = l.seller.call{value: l.price - fee}("");
        if (!ok) revert TransferFailed();
        emit Sold(nft, id, msg.sender, l.price);
    }

    /// @notice Retira comisiones al destinatario.
    function withdrawFees() external {
        uint256 f = accruedFees;
        accruedFees = 0;
        (bool ok,) = feeRecipient.call{value: f}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Lectura de un listado.
    function getListing(address nft, uint256 id) external view returns (address seller, uint256 price) {
        Listing memory l = listings[nft][id];
        return (l.seller, l.price);
    }
}
