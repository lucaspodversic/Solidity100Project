// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title UpgradeableTokenV1 — ERC20 actualizable vía proxy UUPS (ERC-1967)
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #95
/// @notice Arquitectura:
///
///     usuario ──call──▶ ERC1967Proxy (guarda el ESTADO)
///                           │ delegatecall
///                           ▼
///                 UpgradeableTokenV1 (solo LÓGICA)  ──upgrade──▶ V2
///
///   El proxy ejecuta el código de la implementación con `delegatecall`, por
///   lo que el storage vive en el proxy. Actualizar = apuntar el proxy a otra
///   implementación conservando saldos y dirección.
/// @dev Reglas de oro de los contratos actualizables:
///   1. **Sin constructor de estado**: el constructor corre en la
///      implementación, no en el proxy. Se usa `initialize()` (una sola vez,
///      protegido por `initializer`).
///   2. **`_disableInitializers()`** en el constructor: nadie puede
///      inicializar (y adueñarse de) la implementación "desnuda".
///   3. **Layout de storage estable**: V2 no puede reordenar ni cambiar tipos
///      de variables de V1. Aquí usamos **ERC-7201 (namespaced storage)**: todo
///      el estado vive en un struct en un slot calculado por hash, así V2
///      agrega campos AL FINAL del struct sin colisiones.
///   4. **UUPS**: la función de upgrade vive en la implementación y está
///      protegida por `_authorizeUpgrade` (aquí solo el owner). Si una versión
///      olvida heredar UUPSUpgradeable, el contrato queda congelado.
///   Implementamos la lógica ERC20 a mano (versión mínima) con fines
///   didácticos; en producción usá `ERC20Upgradeable` de
///   openzeppelin-contracts-upgradeable.
contract UpgradeableTokenV1 is Initializable, UUPSUpgradeable {
    // ------------------------------------------------------------------
    // Errores y eventos (estándar ERC20)
    // ------------------------------------------------------------------
    error NotOwner();
    error InsufficientBalance(uint256 disponible, uint256 requerido);
    error InsufficientAllowance(uint256 disponible, uint256 requerido);
    error ZeroAddress();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------------
    // Storage namespaced (ERC-7201)
    // ------------------------------------------------------------------

    /// @custom:storage-location erc7201:fundamentos.storage.UpgradeableToken
    struct TokenStorage {
        string name;
        string symbol;
        uint256 totalSupply;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        address owner;
        // ⚠️ V2 solo puede AGREGAR campos debajo de esta línea.
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("fundamentos.storage.UpgradeableToken")) - 1)) & ~bytes32(uint256(0xff))
    ///      Se verifica en los tests (test_SlotERC7201).
    bytes32 internal constant TOKEN_STORAGE_SLOT = 0x9aab624d3eef1e56c7b749017cc7192d93497294bdb4adae84b15780e14a7900;

    /// @dev Devuelve un puntero al struct ubicado en el slot namespaced.
    function _s() internal pure returns (TokenStorage storage $) {
        assembly {
            $.slot := TOKEN_STORAGE_SLOT
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Bloquea la inicialización de la implementación.
        _disableInitializers();
    }

    /// @notice Reemplaza al constructor. Se llama una sola vez a través del proxy.
    function initialize(string calldata name_, string calldata symbol_, address owner_, uint256 initialSupply)
        external
        initializer
    {
        if (owner_ == address(0)) revert ZeroAddress();
        TokenStorage storage $ = _s();
        $.name = name_;
        $.symbol = symbol_;
        $.owner = owner_;
        _mint(owner_, initialSupply);
    }

    modifier onlyOwner() {
        if (msg.sender != _s().owner) revert NotOwner();
        _;
    }

    // ------------------------------ vistas ------------------------------
    function name() external view returns (string memory) { return _s().name; }
    function symbol() external view returns (string memory) { return _s().symbol; }
    function decimals() external pure returns (uint8) { return 18; }
    function totalSupply() external view returns (uint256) { return _s().totalSupply; }
    function balanceOf(address a) external view returns (uint256) { return _s().balances[a]; }
    function allowance(address o, address sp) external view returns (uint256) { return _s().allowances[o][sp]; }
    function owner() external view returns (address) { return _s().owner; }

    /// @notice Versión de la lógica (V2 la sobrescribe).
    function version() external pure virtual returns (string memory) {
        return "1";
    }

    // ---------------------------- ERC20 core ----------------------------
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _s().allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        TokenStorage storage $ = _s();
        uint256 a = $.allowances[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < value) revert InsufficientAllowance(a, value);
            $.allowances[from][msg.sender] = a - value;
        }
        _transfer(from, to, value);
        return true;
    }

    /// @notice Acuñar (solo owner).
    function mint(address to, uint256 value) external onlyOwner {
        _mint(to, value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        TokenStorage storage $ = _s();
        uint256 b = $.balances[from];
        if (b < value) revert InsufficientBalance(b, value);
        unchecked {
            $.balances[from] = b - value; // seguro: b >= value
        }
        $.balances[to] += value;
        emit Transfer(from, to, value);
    }

    function _mint(address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        TokenStorage storage $ = _s();
        $.totalSupply += value;
        $.balances[to] += value;
        emit Transfer(address(0), to, value);
    }

    /// @dev Autorización de upgrade (requisito de UUPS).
    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
