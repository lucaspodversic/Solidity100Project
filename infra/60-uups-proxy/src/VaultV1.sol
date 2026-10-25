// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title VaultV1 — Implementación UUPS versión 1
/// @notice Bóveda de ETH simple (depósitos/retiros por usuario) detrás de un proxy ERC-1967.
/// @dev Patrón UUPS (EIP-1822): la lógica de upgrade vive en la IMPLEMENTACIÓN,
///      no en el proxy. El proxy (`ERC1967Proxy`) solo delega con DELEGATECALL.
///      Ventajas vs. Transparent Proxy: proxy más barato y sin `ProxyAdmin`.
///      Riesgo principal: si una versión nueva NO incluye `upgradeToAndCall`,
///      el contrato queda congelado para siempre; OZ lo mitiga verificando
///      `proxiableUUID()` en la nueva implementación.
///
///      Almacenamiento: usamos **ERC-7201 (namespaced storage)**. Todas las
///      variables viven en un struct ubicado en un slot derivado de un nombre,
///      así futuras versiones pueden agregar campos AL FINAL del struct sin
///      colisionar con nada (ni con slots de herencias nuevas).
contract VaultV1 is Initializable, UUPSUpgradeable {
    /// @custom:storage-location erc7201:solidity100.storage.Vault
    struct VaultStorage {
        address owner;                       // admin que autoriza upgrades
        mapping(address => uint256) balances; // saldo por usuario
        uint256 totalDeposits;               // suma de saldos (invariante)
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("solidity100.storage.Vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant VAULT_STORAGE_SLOT =
        keccak256(abi.encode(uint256(keccak256("solidity100.storage.Vault")) - 1)) & ~bytes32(uint256(0xff));

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();
    error InsufficientBalance();
    error TransferFailed();

    /// @dev Bloquea la implementación: nadie puede llamar `initialize` sobre ella
    ///      directamente (ataque clásico: inicializarla, hacerse owner y
    ///      `selfdestruct`/upgrade desde la implementación).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Inicializador (reemplaza al constructor en proxies). Solo una vez.
    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        _s().owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /// @dev Acceso al struct namespaced (assembly para fijar el slot).
    function _s() internal pure returns (VaultStorage storage $) {
        bytes32 slot = VAULT_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    modifier onlyOwner() {
        if (msg.sender != _s().owner) revert NotOwner();
        _;
    }

    /// @notice Deposita ETH en la cuenta del remitente.
    function deposit() external payable {
        VaultStorage storage $ = _s();
        $.balances[msg.sender] += msg.value;
        $.totalDeposits += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Retira `amount` (CEI: primero estado, luego transferencia).
    function withdraw(uint256 amount) external virtual {
        VaultStorage storage $ = _s();
        if ($.balances[msg.sender] < amount) revert InsufficientBalance();
        $.balances[msg.sender] -= amount;
        $.totalDeposits -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Transfiere la administración.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(_s().owner, newOwner);
        _s().owner = newOwner;
    }

    // ---------------- Lectura ----------------

    function owner() external view returns (address) { return _s().owner; }
    function balanceOf(address user) external view returns (uint256) { return _s().balances[user]; }
    function totalDeposits() external view returns (uint256) { return _s().totalDeposits; }

    /// @notice Versión de la lógica (cada versión la sobreescribe).
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    /// @dev Hook obligatorio de UUPS: SOLO el owner puede actualizar.
    ///      Si esta función no restringe, cualquiera podría apuntar el proxy
    ///      a una implementación maliciosa.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
