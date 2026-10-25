// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PausableVault — bóveda con "botón de pánico" (pausa de emergencia)
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #82
/// @notice Implementación didáctica *desde cero* del patrón circuit breaker
///         (equivalente al `Pausable` de OpenZeppelin, que en producción
///         conviene usar directamente). Cuando el guardián pausa:
///         - depósitos y retiros normales se bloquean (`whenNotPaused`);
///         - se habilita `emergencyWithdraw` (`whenPaused`) para que los
///           usuarios puedan rescatar sus fondos sin lógica extra.
/// @dev Consideraciones: la pausa es un poder centralizado. Documentá quién
///      la controla (idealmente un multisig, proyecto #94) y considerá un
///      límite de duración para que no sea un "rug" encubierto.
contract PausableVault {
    error NotGuardian();
    error EnforcedPause();
    error ExpectedPause();
    error InsufficientBalance();
    error TransferFailed();

    event Paused(address account);
    event Unpaused(address account);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Cuenta autorizada a pausar/despausar.
    address public immutable guardian;
    /// @notice ¿Está pausado el contrato?
    bool public paused;
    /// @notice Saldos de cada usuario.
    mapping(address => uint256) public balances;

    constructor() {
        guardian = msg.sender;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /// @dev Bloquea la función mientras esté pausado.
    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    /// @dev Solo permite la función mientras esté pausado.
    modifier whenPaused() {
        if (!paused) revert ExpectedPause();
        _;
    }

    /// @notice Activar la pausa de emergencia.
    function pause() external onlyGuardian whenNotPaused {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Reanudar la operación normal.
    function unpause() external onlyGuardian whenPaused {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function deposit() external payable whenNotPaused {
        balances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external whenNotPaused {
        _withdraw(amount);
    }

    /// @notice Durante la pausa el usuario puede retirar todo su saldo.
    function emergencyWithdraw() external whenPaused {
        _withdraw(balances[msg.sender]);
    }

    /// @dev Lógica común de retiro con CEI.
    function _withdraw(uint256 amount) internal {
        if (amount == 0 || balances[msg.sender] < amount) revert InsufficientBalance();
        balances[msg.sender] -= amount;
        emit Withdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
