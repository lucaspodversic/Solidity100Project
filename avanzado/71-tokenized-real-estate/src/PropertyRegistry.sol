// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PropertyRegistry — NFTs de escrituras + registro KYC
/// @notice Cada inmueble es un NFT (ERC-721) emitido por el **registrador** (entidad legal que
///         verificó la escritura, la SPV o el fideicomiso). El NFT guarda el hash del documento
///         legal y la tasación. El registrador también mantiene la lista de inversores con KYC
///         que pueden tener fracciones (requisito regulatorio típico de security tokens).
contract PropertyRegistry is ERC721, Ownable {
    struct Property {
        bytes32 deedHash; // hash del PDF de la escritura o el contrato de fideicomiso
        string uri; // metadata (IPFS): dirección, fotos, m²
        uint256 appraisalWei; // última tasación informada
    }

    uint256 public nextId = 1;
    mapping(uint256 => Property) public properties;
    mapping(address => bool) public isVerified;

    event PropertyMinted(uint256 indexed id, address indexed to, bytes32 deedHash, uint256 appraisal);
    event Verified(address indexed who, bool ok);
    event Appraised(uint256 indexed id, uint256 value);

    constructor(address registrar) ERC721("Tokenized Real Estate Deed", "DEED") Ownable(registrar) {}

    /// @notice Alta o baja de KYC.
    function setVerified(address who, bool ok) external onlyOwner {
        isVerified[who] = ok;
        emit Verified(who, ok);
    }

    /// @notice Emite el NFT de un inmueble (normalmente directo a su DAO).
    function mintProperty(address to, bytes32 deedHash, string calldata uri, uint256 appraisal)
        external
        onlyOwner
        returns (uint256 id)
    {
        id = nextId++;
        properties[id] = Property(deedHash, uri, appraisal);
        _safeMint(to, id);
        emit PropertyMinted(id, to, deedHash, appraisal);
    }

    function setAppraisal(uint256 id, uint256 value) external onlyOwner {
        _requireOwned(id);
        properties[id].appraisalWei = value;
        emit Appraised(id, value);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return properties[id].uri;
    }
}
