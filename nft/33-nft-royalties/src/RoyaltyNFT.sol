// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RoyaltyNFT — ERC721 + ERC2981 (royalties on-chain)
/// @author Proyecto 33
/// @notice Define un royalty default a nivel colección y permite override por token.
contract RoyaltyNFT is ERC721, ERC2981, Ownable {
    uint256 public nextId = 1;
    constructor(address receiver, uint96 feeNumerator)
        ERC721("RoyaltyNFT", "RNFT") Ownable(msg.sender)
    {
        // feeNumerator en basis points de 10000 (ej: 500 = 5%)
        _setDefaultRoyalty(receiver, feeNumerator);
    }
    function mint(address to) external onlyOwner returns (uint256 id) {
        id = nextId++;
        _mint(to, id);
    }
    /// @notice Override de royalty para un token puntual.
    function setTokenRoyalty(uint256 tokenId, address receiver, uint96 fee) external onlyOwner {
        _setTokenRoyalty(tokenId, receiver, fee);
    }
    function supportsInterface(bytes4 iid) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(iid);
    }
}
