// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PiggyBank — "producto" que despliega la fábrica
/// @notice Alcancía de ETH con dueño y fecha de desbloqueo. Es intencionalmente
///         simple: el foco del proyecto es el patrón Factory, no el producto.
/// @dev Soporta dos modos de creación:
///      - Constructor clásico (`new` / CREATE2 con bytecode completo).
///      - Clon mínimo EIP-1167 + `initialize` (no hay constructor en los clones).
contract PiggyBank {
    /// @notice Dueño que puede retirar.
    address public owner;
    /// @notice Timestamp a partir del cual se puede retirar.
    uint64 public unlockTime;
    /// @notice Fábrica que creó la instancia (para trazabilidad).
    address public factory;
    /// @dev Evita reinicializar un clon (o inicializar la implementación).
    bool private _initialized;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotOwner();
    error StillLocked(uint64 unlockTime);
    error TransferFailed();

    /// @dev Si `_owner` es cero dejamos la instancia "vacía" para usarla como
    ///      implementación de clones y la bloqueamos (`_initialized = true`)
    ///      para que nadie pueda tomarla.
    constructor(address _owner, uint64 _unlockTime) {
        if (_owner == address(0)) {
            _initialized = true; // implementación bloqueada
            return;
        }
        _init(_owner, _unlockTime, msg.sender);
    }

    /// @notice Inicializador para clones EIP-1167 (llamado UNA vez por la fábrica).
    function initialize(address _owner, uint64 _unlockTime) external {
        _init(_owner, _unlockTime, msg.sender);
    }

    /// @notice Depositar ETH.
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Retira todo el saldo al dueño, si ya pasó `unlockTime`.
    function withdraw() external {
        if (msg.sender != owner) revert NotOwner();
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);
        uint256 bal = address(this).balance;
        (bool ok,) = owner.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(owner, bal);
    }

    /// @dev Lógica común de inicialización.
    function _init(address _owner, uint64 _unlockTime, address _factory) private {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        owner = _owner;
        unlockTime = _unlockTime;
        factory = _factory;
    }
}
