// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title OnchainNFT — metadatos SVG 100% on-chain (sin IPFS)
/// @author Proyecto 32
/// @notice Cada tokenURI es un data URI `data:application/json;base64,...` cuyo campo
///         `image` es a su vez un SVG embebido en base64. Nada se almacena off-chain.
/// @dev Ideal para colecciones pequeñas: el gas de mint crece con el tamaño del SVG.
contract OnchainNFT is ERC721, Ownable {
    using Strings for uint256;

    uint256 public nextId = 1;
    uint256 public immutable maxSupply;
    /// @notice Semilla aleatoria por token (derivada del bloque + minter + id).
    mapping(uint256 => uint256) public seedOf;

    constructor(uint256 maxSupply_) ERC721("OnchainArt", "OART") Ownable(msg.sender) {
        maxSupply = maxSupply_;
    }

    /// @notice Acuña un token con semilla determinística.
    function mint() external returns (uint256 id) {
        require(nextId <= maxSupply, "agotado");
        id = nextId++;
        // Semilla: mezcla block.prevrandao, timestamp, minter e id. No es VRF seguro
        // (un minero puede influir), pero alcanza para arte generativo demo.
        seedOf[id] = uint256(keccak256(abi.encodePacked(block.prevrandao, block.timestamp, msg.sender, id)));
        _mint(msg.sender, id);
    }

    /// @notice Genera el tokenURI como data URI JSON+SVG on-chain.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint256 seed = seedOf[tokenId];
        string memory svg = _buildSVG(tokenId, seed);
        string memory json = string.concat(
            '{"name":"Onchain #', tokenId.toString(),
            '","description":"Arte generativo 100% on-chain.",',
            '"attributes":[{"trait_type":"Hue","value":', (seed % 360).toString(),
            '},{"trait_type":"Rarity","value":"', _rarity(seed), '"}],',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev Construye un SVG simple coloreado según la semilla.
    function _buildSVG(uint256 tokenId, uint256 seed) internal pure returns (string memory) {
        uint256 hue = seed % 360;
        uint256 sat = 50 + (seed / 360) % 50;
        uint256 light = 40 + (seed / 360 / 50) % 40;
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400">',
            '<rect width="100%" height="100%" fill="hsl(', hue.toString(), ',', sat.toString(), '%,', light.toString(), '%)"/>',
            '<text x="50%" y="50%" dominant-baseline="middle" text-anchor="middle" fill="white" font-size="48" font-family="monospace">#',
            tokenId.toString(), '</text></svg>'
        );
    }

    function _rarity(uint256 seed) internal pure returns (string memory) {
        uint256 r = seed % 100;
        if (r < 5) return "Legendary";
        if (r < 20) return "Rare";
        if (r < 50) return "Uncommon";
        return "Common";
    }
}
