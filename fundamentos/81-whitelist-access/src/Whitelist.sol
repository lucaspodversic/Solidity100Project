// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Whitelist — control de acceso por lista blanca
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #81
/// @notice El dueño agrega/quita direcciones. Solo las direcciones en la lista
///         pueden llamar funciones marcadas con `onlyWhitelisted` (en este
///         ejemplo, `mint` de un contador de "cupos" y `claim`).
/// @dev Lista blanca "en cadena" con `mapping(address => bool)`: lectura O(1),
///      pero cada alta cuesta ~22k gas (SSTORE de cero a no-cero). Para miles
///      de direcciones conviene Merkle (proyecto #93).
contract Whitelist is Ownable {
    error NotWhitelisted(address cuenta);
    error AlreadyClaimed(address cuenta);
    error ZeroAddress();

    event AddedToWhitelist(address indexed account);
    event RemovedFromWhitelist(address indexed account);
    event Claimed(address indexed account);

    /// @notice Estado de cada dirección en la lista.
    mapping(address => bool) public isWhitelisted;
    /// @notice Cantidad de direcciones activas en la lista.
    uint256 public whitelistCount;
    /// @notice Registro de quién ya reclamó su beneficio.
    mapping(address => bool) public claimed;
    /// @notice Total de reclamos (dato de ejemplo).
    uint256 public totalClaims;

    constructor() Ownable(msg.sender) {}

    /// @dev Modificador reutilizable: revierte si el emisor no está listado.
    modifier onlyWhitelisted() {
        if (!isWhitelisted[msg.sender]) revert NotWhitelisted(msg.sender);
        _;
    }

    /// @notice Agrega una dirección (idempotente: repetir no duplica el contador).
    function add(address account) public onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (!isWhitelisted[account]) {
            isWhitelisted[account] = true;
            whitelistCount++;
            emit AddedToWhitelist(account);
        }
    }

    /// @notice Alta masiva. Ojo con el límite de gas del bloque si la lista es enorme.
    function addBatch(address[] calldata accounts) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            add(accounts[i]);
        }
    }

    /// @notice Quita una dirección (borrar a cero devuelve parte del gas).
    function remove(address account) external onlyOwner {
        if (isWhitelisted[account]) {
            isWhitelisted[account] = false;
            whitelistCount--;
            emit RemovedFromWhitelist(account);
        }
    }

    /// @notice Función restringida de ejemplo: un reclamo por dirección.
    function claim() external onlyWhitelisted {
        if (claimed[msg.sender]) revert AlreadyClaimed(msg.sender);
        claimed[msg.sender] = true;
        totalClaims++;
        emit Claimed(msg.sender);
    }
}
