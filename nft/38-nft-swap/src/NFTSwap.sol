// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NFTSwap — intercambio trustless de NFTs (1:1 o N:M con sweetener ETH)
/// @author Proyecto 38
/// @notice Alice crea una oferta depositando sus NFTs (+ ETH opcional). Bob la acepta
///         depositando los suyos. Si nadie acepta, Alice cancela y recupera todo.
contract NFTSwap is ReentrancyGuard {
    struct Item { address nft; uint256 tokenId; }
    struct Offer {
        address maker;
        Item[] offering;   // lo que pone el maker
        Item[] wanting;    // lo que pide
        uint256 ethOffer;  // ETH que pone el maker
        uint256 ethWant;   // ETH que pide
        bool active;
    }
    uint256 public nextId = 1;
    mapping(uint256 => Offer) private _offers;

    event Created(uint256 id, address maker);
    event Accepted(uint256 id, address taker);
    event Cancelled(uint256 id);

    error NotActive(); error NotMaker(); error BadPay(); error TransferFail();

    function create(Item[] calldata offering, Item[] calldata wanting, uint256 ethWant)
        external payable nonReentrant returns (uint256 id)
    {
        id = nextId++;
        Offer storage O = _offers[id];
        O.maker = msg.sender;
        O.ethOffer = msg.value;
        O.ethWant = ethWant;
        O.active = true;
        for (uint i; i < offering.length; ++i) {
            O.offering.push(offering[i]);
            IERC721(offering[i].nft).transferFrom(msg.sender, address(this), offering[i].tokenId);
        }
        for (uint i; i < wanting.length; ++i) O.wanting.push(wanting[i]);
        emit Created(id, msg.sender);
    }

    function accept(uint256 id) external payable nonReentrant {
        Offer storage O = _offers[id];
        if (!O.active) revert NotActive();
        if (msg.value != O.ethWant) revert BadPay();
        O.active = false;

        // Taker entrega lo pedido
        for (uint i; i < O.wanting.length; ++i) {
            IERC721(O.wanting[i].nft).transferFrom(msg.sender, O.maker, O.wanting[i].tokenId);
        }
        // Maker recibe ETH pedido
        if (O.ethWant > 0) {
            (bool ok,) = O.maker.call{value: O.ethWant}("");
            if (!ok) revert TransferFail();
        }
        // Taker recibe lo ofrecido + ETH del maker
        for (uint i; i < O.offering.length; ++i) {
            IERC721(O.offering[i].nft).transferFrom(address(this), msg.sender, O.offering[i].tokenId);
        }
        if (O.ethOffer > 0) {
            (bool ok,) = msg.sender.call{value: O.ethOffer}("");
            if (!ok) revert TransferFail();
        }
        emit Accepted(id, msg.sender);
    }

    function cancel(uint256 id) external nonReentrant {
        Offer storage O = _offers[id];
        if (!O.active) revert NotActive();
        if (O.maker != msg.sender) revert NotMaker();
        O.active = false;
        for (uint i; i < O.offering.length; ++i) {
            IERC721(O.offering[i].nft).transferFrom(address(this), msg.sender, O.offering[i].tokenId);
        }
        if (O.ethOffer > 0) {
            (bool ok,) = msg.sender.call{value: O.ethOffer}("");
            if (!ok) revert TransferFail();
        }
        emit Cancelled(id);
    }

    function getOffer(uint256 id) external view returns (
        address maker, uint256 ethOffer, uint256 ethWant, bool active,
        Item[] memory offering, Item[] memory wanting
    ) {
        Offer storage O = _offers[id];
        return (O.maker, O.ethOffer, O.ethWant, O.active, O.offering, O.wanting);
    }
}
