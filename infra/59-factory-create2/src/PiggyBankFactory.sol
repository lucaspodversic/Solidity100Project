// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PiggyBank} from "./PiggyBank.sol";

/// @title PiggyBankFactory — Patrón Factory con tres estrategias de despliegue
/// @notice Compara:
///   1. `CREATE`  (`new PiggyBank(...)`): dirección depende del nonce de la fábrica.
///   2. `CREATE2` (`new PiggyBank{salt: s}(...)`): dirección determinista y
///      precomputable = keccak256(0xff ++ factory ++ salt ++ keccak256(initcode))[12:].
///   3. Clon mínimo EIP-1167 vía CREATE2 (`Clones.cloneDeterministic`): ~45 bytes de
///      runtime que delegan a una implementación; desplegar cuesta ~10x menos gas.
/// @dev La sal efectiva siempre se liga a `msg.sender` (`keccak256(sender, salt)`)
///      para impedir que un tercero "robe" (front-run) la dirección de otro usuario
///      desplegando antes con la misma sal y parámetros distintos.
contract PiggyBankFactory {
    /// @notice Implementación compartida por todos los clones.
    address public immutable implementation;
    /// @notice Registro de todas las instancias desplegadas.
    address[] public allBanks;
    /// @notice Instancias por dueño.
    mapping(address => address[]) public banksOf;
    /// @notice Si una dirección fue creada por esta fábrica (verificación barata).
    mapping(address => bool) public isFromFactory;

    /// @notice Modo de despliegue para el evento.
    enum Mode { Create, Create2, Clone }

    event BankCreated(address indexed bank, address indexed owner, Mode mode, bytes32 salt);

    constructor() {
        // Implementación con owner = 0 => queda bloqueada (no inicializable).
        implementation = address(new PiggyBank(address(0), 0));
    }

    // ------------------------------------------------------------------
    // 1) CREATE clásico
    // ------------------------------------------------------------------

    /// @notice Despliega con CREATE (`new`). Dirección no predecible por el usuario.
    function createBank(uint64 unlockTime) external returns (address bank) {
        bank = address(new PiggyBank(msg.sender, unlockTime));
        _register(bank, msg.sender, Mode.Create, bytes32(0));
    }

    // ------------------------------------------------------------------
    // 2) CREATE2 con bytecode completo
    // ------------------------------------------------------------------

    /// @notice Despliega con CREATE2. La dirección es conocida de antemano.
    /// @param salt Sal elegida por el usuario (se combina con msg.sender).
    function createBank2(uint64 unlockTime, bytes32 salt) external returns (address bank) {
        bytes32 s = _userSalt(msg.sender, salt);
        bank = address(new PiggyBank{salt: s}(msg.sender, unlockTime));
        _register(bank, msg.sender, Mode.Create2, salt);
    }

    /// @notice Predice la dirección de `createBank2` sin desplegar.
    /// @dev Fórmula de EIP-1014. El initcode incluye los argumentos del constructor,
    ///      por eso dueño y unlockTime cambian la dirección.
    function predictBank2(address owner, uint64 unlockTime, bytes32 salt) public view returns (address) {
        bytes memory initCode = abi.encodePacked(type(PiggyBank).creationCode, abi.encode(owner, unlockTime));
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), _userSalt(owner, salt), keccak256(initCode)));
        return address(uint160(uint256(h)));
    }

    // ------------------------------------------------------------------
    // 3) Clon mínimo EIP-1167 determinista
    // ------------------------------------------------------------------

    /// @notice Despliega un clon EIP-1167 con CREATE2 y lo inicializa en la MISMA tx
    ///         (evita que alguien inicialice el clon antes que nosotros).
    function createBankClone(uint64 unlockTime, bytes32 salt) external returns (address bank) {
        bank = Clones.cloneDeterministic(implementation, _userSalt(msg.sender, salt));
        PiggyBank(payable(bank)).initialize(msg.sender, unlockTime);
        _register(bank, msg.sender, Mode.Clone, salt);
    }

    /// @notice Predice la dirección del clon. Para clones el initcode es fijo,
    ///         así que la dirección solo depende de (fábrica, sal, implementación).
    function predictClone(address owner, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _userSalt(owner, salt), address(this));
    }

    // ------------------------------------------------------------------
    // Lectura
    // ------------------------------------------------------------------

    /// @notice Cantidad total de alcancías.
    function totalBanks() external view returns (uint256) {
        return allBanks.length;
    }

    /// @notice Alcancías de un dueño.
    function getBanksOf(address owner) external view returns (address[] memory) {
        return banksOf[owner];
    }

    // ------------------------------------------------------------------
    // Internas
    // ------------------------------------------------------------------

    /// @dev Liga la sal al usuario: anti front-running de direcciones.
    function _userSalt(address user, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, salt));
    }

    /// @dev Guarda la instancia en los registros y emite evento.
    function _register(address bank, address owner, Mode mode, bytes32 salt) internal {
        allBanks.push(bank);
        banksOf[owner].push(bank);
        isFromFactory[bank] = true;
        emit BankCreated(bank, owner, mode, salt);
    }
}
