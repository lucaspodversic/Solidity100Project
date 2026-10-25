// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RoyaltyMarketplace — marketplace que respeta ERC2981
/// @author Proyecto 33
/// @notice Al comprar, consulta `royaltyInfo` y reparte precio = royalty + seller.
contract RoyaltyMarketplace is ReentrancyGuard {
    struct Listing { address seller; address nft; uint256 tokenId; uint256 price; bool active; }
    uint256 public nextId = 1;
    mapping(uint256 => Listing) public listings;

    event Listed(uint256 id, address seller, address nft, uint256 tokenId, uint256 price);
    event Sold(uint256 id, address buyer, uint256 price, uint256 royalty, address receiver);

    error NotOwner(); error NotActive(); error BadPay(); error PayFail();

    function list(address nft, uint256 tokenId, uint256 price) external nonReentrant returns (uint256 id) {
        if (IERC721(nft).ownerOf(tokenId) != msg.sender) revert NotOwner();
        id = nextId++;
        listings[id] = Listing(msg.sender, nft, tokenId, price, true);
        IERC721(nft).transferFrom(msg.sender, address(this), tokenId);
        emit Listed(id, msg.sender, nft, tokenId, price);
    }

    function buy(uint256 id) external payable nonReentrant {
        Listing storage L = listings[id];
        if (!L.active) revert NotActive();
        if (msg.value != L.price) revert BadPay();
        L.active = false;

        // Consultamos royalty ERC2981 si el NFT lo soporta.
        uint256 royalty;
        address receiver;
        try IERC2981(L.nft).royaltyInfo(L.tokenId, L.price) returns (address r, uint256 amt) {
            receiver = r; royalty = amt > L.price ? L.price : amt;
        } catch {}

        IERC721(L.nft).transferFrom(address(this), msg.sender, L.tokenId);
        if (royalty > 0 && receiver != address(0)) {
            (bool ok1,) = receiver.call{value: royalty}("");
            if (!ok1) revert PayFail();
        }
        (bool ok2,) = L.seller.call{value: L.price - royalty}("");
        if (!ok2) revert PayFail();
        emit Sold(id, msg.sender, L.price, royalty, receiver);
    }
}
