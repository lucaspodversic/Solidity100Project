// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {MockVRF} from "./MockVRF.sol";

/// @title DynamicNFT — atributos que cambian según un feed on-chain (mock Chainlink)
/// @author Proyecto 37
/// @notice El "nivel" de cada NFT se deriva de `oracle.latest` + una semilla propia.
///         Cuando el oracle actualiza, el tokenURI cambia sin tocar storage del NFT.
contract DynamicNFT is ERC721, Ownable {
    using Strings for uint256;
    MockVRF public immutable oracle;
    uint256 public nextId = 1;
    mapping(uint256 => uint256) public seedOf;

    constructor(address oracle_) ERC721("Dynamic", "DYN") Ownable(msg.sender) {
        oracle = MockVRF(oracle_);
    }

    function mint() external returns (uint256 id) {
        id = nextId++;
        seedOf[id] = uint256(keccak256(abi.encode(id, msg.sender, block.prevrandao)));
        _mint(msg.sender, id);
    }

    /// @notice Nivel dinámico = (oracle.latest + seed) % 100.
    function level(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        return (oracle.latest() + seedOf[tokenId]) % 100;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint256 lvl = level(tokenId);
        string memory stage = lvl < 25 ? "Egg" : lvl < 50 ? "Hatchling" : lvl < 75 ? "Adult" : "Legend";
        string memory json = string.concat(
            '{"name":"Dyn #', tokenId.toString(),
            '","attributes":[{"trait_type":"Level","value":', lvl.toString(),
            '},{"trait_type":"Stage","value":"', stage,
            '"},{"trait_type":"OracleRound","value":', oracle.round().toString(), '}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
