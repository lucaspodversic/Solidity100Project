// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title LeaseNFT — Activos alquilables con rol de "usuario" (ERC-4907)
/// @notice Separa **propiedad** (`ownerOf`) de **uso** (`userOf`, con vencimiento). El dueño
///         cobra la renta y el inquilino usa el activo (abre la cerradura inteligente, accede al
///         coche o al software). Solo el `RentVault` puede asignar usuarios, así nadie (ni el
///         dueño) puede echar a un inquilino al día ni meter un usuario sin contrato.
contract LeaseNFT is ERC721 {
    struct UserInfo {
        address user;
        uint64 expires;
    }

    /// @notice ERC-4907
    event UpdateUser(uint256 indexed tokenId, address indexed user, uint64 expires);

    error OnlyVault();

    address public immutable vault;
    uint256 public nextId = 1;
    mapping(uint256 => UserInfo) internal _users;
    mapping(uint256 => string) internal _uris;

    constructor(address _vault) ERC721("Lease Asset", "LEASE") {
        vault = _vault;
    }

    /// @notice Cualquiera tokeniza un activo propio (en producción: verificación del activo físico).
    function mint(string calldata uri) external returns (uint256 id) {
        id = nextId++;
        _uris[id] = uri;
        _mint(msg.sender, id);
    }

    /// @notice ERC-4907 `setUser`, restringido al vault.
    function setUser(uint256 id, address user, uint64 expires) external {
        if (msg.sender != vault) revert OnlyVault();
        _users[id] = UserInfo(user, expires);
        emit UpdateUser(id, user, expires);
    }

    /// @notice Usuario vigente (address(0) si venció).
    function userOf(uint256 id) external view returns (address) {
        UserInfo memory u = _users[id];
        return block.timestamp < u.expires ? u.user : address(0);
    }

    function userExpires(uint256 id) external view returns (uint256) {
        return _users[id].expires;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return _uris[id];
    }

    function supportsInterface(bytes4 iid) public view override returns (bool) {
        return iid == 0xad092b5c /* IERC4907 */ || super.supportsInterface(iid);
    }
}
