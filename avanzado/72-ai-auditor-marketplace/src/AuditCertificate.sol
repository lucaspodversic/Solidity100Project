// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title AuditCertificate — Certificados de auditoría **soulbound** (ERC-721 + ERC-5192)
/// @notice Cada certificado vincula: el contrato auditado (`target` y su `codehash` en el momento
///         de la auditoría), el agente IA que auditó, y el hash del informe (IPFS). No se puede
///         transferir: un certificado que se compra o se vende no vale nada.
/// @dev ERC-5192 ("Minimal Soulbound NFTs"): `locked(id)` siempre devuelve true y se emite `Locked`
///      al acuñar. Las transferencias revierten en `_update` (se permite mint y burn).
contract AuditCertificate is ERC721 {
    struct Cert {
        address target;
        bytes32 codehash;
        uint256 auditorId;
        bytes32 reportHash;
        uint64 issuedAt;
        bool revoked;
    }

    /// @notice ERC-5192
    event Locked(uint256 tokenId);
    event Revoked(uint256 indexed tokenId, string reason);

    error Soulbound();
    error OnlyMarket();

    address public immutable market;
    uint256 public nextId = 1;
    mapping(uint256 => Cert) public certs;

    constructor() ERC721("AI Audit Certificate", "AUDIT") {
        market = msg.sender;
    }

    modifier onlyMarket() {
        if (msg.sender != market) revert OnlyMarket();
        _;
    }

    function issue(address to, Cert calldata c) external onlyMarket returns (uint256 id) {
        id = nextId++;
        certs[id] = c;
        _mint(to, id);
        emit Locked(id);
    }

    function revoke(uint256 id, string calldata reason) external onlyMarket {
        certs[id].revoked = true;
        emit Revoked(id, reason);
    }

    /// @notice ERC-5192: siempre bloqueado.
    function locked(uint256 id) external view returns (bool) {
        _requireOwned(id);
        return true;
    }

    /// @notice ¿El certificado sigue siendo válido para el código ACTUAL del target?
    /// @dev Si el contrato se redesplegó o fue un proxy actualizado con otro código, el codehash cambia.
    function isValid(uint256 id) public view returns (bool) {
        Cert storage c = certs[id];
        return c.issuedAt != 0 && !c.revoked && c.target.codehash == c.codehash;
    }

    function supportsInterface(bytes4 iid) public view override returns (bool) {
        return iid == 0xb45a3c0e /* IERC5192 */ || super.supportsInterface(iid);
    }

    /// @dev Bloquea transferencias: solo mint (from = 0) o burn (to = 0).
    function _update(address to, uint256 id, address auth) internal override returns (address) {
        address from = _ownerOf(id);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, id, auth);
    }
}
