// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPFSRegistry — guardar referencias a archivos IPFS en cadena
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #92
/// @notice Guardar archivos en la blockchain es carísimo (~20k gas por 32
///         bytes). Lo habitual es subir el archivo a IPFS y guardar solo su
///         CID (Content IDentifier). Como el CID deriva del contenido, el
///         contrato "ancla" el archivo: si alguien lo altera, el CID cambia.
/// @dev Dos formas de almacenar el CID:
///   1. **string** ("bafy..." CIDv1 o "Qm..." CIDv0): flexible, fácil de usar
///      desde el front, pero ocupa varios slots (~59 bytes => 3 slots).
///   2. **bytes32 digest**: un CIDv0 "Qm..." es base58( 0x12 0x20 + sha256 ).
///      Los 2 primeros bytes son fijos (multihash sha2-256, 32 bytes), así que
///      basta guardar el digest de 32 bytes => 1 solo slot. El front
///      reconstruye el CID agregando 0x1220 y codificando en base58.
contract IPFSRegistry {
    error EmptyCid();
    error NotDocumentOwner();
    error UnknownDocument();

    event DocumentStored(uint256 indexed id, address indexed owner, string cid);
    event DocumentUpdated(uint256 indexed id, string oldCid, string newCid);
    event DigestStored(address indexed owner, bytes32 digest);

    struct Document {
        address owner;     // 20 bytes
        uint64 createdAt;  // 8 bytes (empaquetado con owner en 1 slot)
        string cid;        // CID completo como texto
    }

    /// @notice Documentos por id (desde 1).
    mapping(uint256 => Document) public documents;
    /// @notice Ids de documentos de cada usuario (para listarlos en el front).
    mapping(address => uint256[]) private _byOwner;
    uint256 public nextId = 1;

    /// @notice Variante compacta: digest sha256 del CIDv0 por usuario.
    mapping(address => bytes32) public profileDigest;

    /// @notice Registrar un CID como texto.
    function store(string calldata cid) external returns (uint256 id) {
        if (bytes(cid).length == 0) revert EmptyCid();
        id = nextId++;
        documents[id] = Document(msg.sender, uint64(block.timestamp), cid);
        _byOwner[msg.sender].push(id);
        emit DocumentStored(id, msg.sender, cid);
    }

    /// @notice Actualizar el CID (nueva versión del archivo).
    /// @dev El historial completo queda en los eventos, no en storage.
    function update(uint256 id, string calldata newCid) external {
        Document storage d = documents[id];
        if (d.owner == address(0)) revert UnknownDocument();
        if (d.owner != msg.sender) revert NotDocumentOwner();
        if (bytes(newCid).length == 0) revert EmptyCid();
        emit DocumentUpdated(id, d.cid, newCid);
        d.cid = newCid;
    }

    /// @notice Ids de documentos de un usuario.
    function documentsOf(address owner) external view returns (uint256[] memory) {
        return _byOwner[owner];
    }

    /// @notice URL lista para un gateway público.
    function uri(uint256 id) external view returns (string memory) {
        if (documents[id].owner == address(0)) revert UnknownDocument();
        return string.concat("ipfs://", documents[id].cid);
    }

    /// @notice Guardar solo el digest de 32 bytes (variante barata, 1 slot).
    function storeDigest(bytes32 digest) external {
        profileDigest[msg.sender] = digest;
        emit DigestStored(msg.sender, digest);
    }

    /// @notice Devuelve el multihash completo (0x1220 + digest) listo para base58.
    function multihashOf(address owner) external view returns (bytes memory) {
        return abi.encodePacked(hex"1220", profileDigest[owner]);
    }
}
