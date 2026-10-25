// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MerkleAirdrop — whitelist eficiente con árbol de Merkle
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #93
/// @notice En vez de guardar N direcciones (N × 22k gas), guardamos UNA raíz
///         de 32 bytes. Cada usuario presenta una prueba de log2(N) hashes que
///         demuestra que (índice, cuenta, monto) es una hoja del árbol.
/// @dev Detalles de seguridad:
///   - **Doble hash de la hoja** `keccak256(bytes.concat(keccak256(abi.encode(...))))`:
///     evita el ataque de "segunda preimagen", donde un nodo interno (64
///     bytes) se hace pasar por hoja. Es el formato del StandardMerkleTree
///     de OpenZeppelin (paquete npm "openzeppelin merkle-tree" en JS).
///   - `abi.encode` (no `encodePacked`) para evitar ambigüedades.
///   - **BitMaps** para marcar reclamos: 256 reclamos por slot (barato).
///   - MerkleProof de OZ ordena cada par antes de hashear (commutativo), así
///     la prueba no necesita indicar izquierda/derecha.
contract MerkleAirdrop is ERC20 {
    using BitMaps for BitMaps.BitMap;

    error AlreadyClaimed(uint256 index);
    error InvalidProof();

    event Claimed(uint256 indexed index, address indexed account, uint256 amount);

    /// @notice Raíz del árbol con todas las asignaciones.
    bytes32 public immutable merkleRoot;
    /// @dev Bit `index` = 1 si ya se reclamó.
    BitMaps.BitMap private _claimed;

    constructor(bytes32 root) ERC20("Airdrop Token", "AIR") {
        merkleRoot = root;
    }

    /// @notice Hoja canónica (pública para que tests y front la reproduzcan).
    function leaf(uint256 index, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function isClaimed(uint256 index) external view returns (bool) {
        return _claimed.get(index);
    }

    /// @notice Reclamar la asignación demostrando pertenencia a la whitelist.
    /// @dev Cualquiera puede enviar la tx por la cuenta (los tokens van a `account`).
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        if (_claimed.get(index)) revert AlreadyClaimed(index);
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf(index, account, amount))) revert InvalidProof();
        _claimed.set(index);
        _mint(account, amount);
        emit Claimed(index, account, amount);
    }
}
