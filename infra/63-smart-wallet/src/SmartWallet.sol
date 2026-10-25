// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title SmartWallet — Billetera inteligente con autenticación por `msg.sender`
/// @notice Funcionalidades:
///   - **Owner** con control total (autenticado por `msg.sender`).
///   - **Operadores** (p. ej. un bot o un celular secundario) con límite de gasto
///     diario en ETH y lista blanca de destinos.
///   - **Ejecución por lotes** (`executeBatch`) para hacer varias acciones atómicas.
///   - **Recuperación social**: si el owner pierde su clave, `threshold` guardianes
///     pueden proponer un nuevo owner; se aplica tras un retraso de 2 días durante
///     el cual el owner actual puede cancelar (protección contra guardianes coludidos).
///   - **EIP-1271**: valida firmas del owner para que dApps acepten "firmas de la wallet".
/// @dev Toda autorización se basa en `msg.sender` (no en `tx.origin`, que es
///      vulnerable a phishing: un contrato malicioso llamado por el owner tendría
///      `tx.origin == owner`).
contract SmartWallet is IERC1271 {
    using ECDSA for bytes32;

    /// @notice Una llamada dentro de un lote.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice Configuración de un operador.
    struct Operator {
        bool enabled;
        uint128 dailyLimit;   // máximo de wei por día
        uint128 spentToday;   // gastado en el día actual
        uint64 day;           // día (timestamp / 1 days) del contador
    }

    /// @notice Propuesta de recuperación en curso.
    struct Recovery {
        address newOwner;
        uint64 executeAfter;
        uint32 approvals;
        uint32 round; // ronda para invalidar aprobaciones de propuestas anteriores
    }

    /// @notice Retraso obligatorio para la recuperación.
    uint256 public constant RECOVERY_DELAY = 2 days;
    /// @dev Valor mágico de EIP-1271.
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    address public owner;
    mapping(address => Operator) public operators;
    /// @notice operador => destino => permitido.
    mapping(address => mapping(address => bool)) public allowedTarget;

    mapping(address => bool) public isGuardian;
    uint256 public guardianCount;
    uint256 public guardianThreshold;
    Recovery public recovery;
    /// @notice ronda => guardián => aprobó.
    mapping(uint32 => mapping(address => bool)) public approvedRecovery;

    event Executed(address indexed by, address indexed target, uint256 value, bytes data);
    event OperatorSet(address indexed op, bool enabled, uint128 dailyLimit);
    event TargetAllowed(address indexed op, address indexed target, bool allowed);
    event GuardianSet(address indexed guardian, bool active);
    event RecoveryProposed(address indexed newOwner, uint64 executeAfter);
    event RecoveryApproved(address indexed guardian, uint32 approvals);
    event RecoveryCancelled();
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event Received(address indexed from, uint256 amount);

    error Unauthorized();
    error TargetNotAllowed(address target);
    error DailyLimitExceeded(uint256 requested, uint256 available);
    error CallFailed(uint256 index, bytes reason);
    error InvalidConfig();
    error NoRecovery();
    error RecoveryNotReady();
    error AlreadyApproved();
    error OperatorCannotCallSelf();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @param _owner Dueño inicial.
    /// @param guardians Guardianes iniciales para la recuperación social.
    /// @param threshold Aprobaciones necesarias para recuperar.
    constructor(address _owner, address[] memory guardians, uint256 threshold) {
        if (_owner == address(0)) revert InvalidConfig();
        if (guardians.length > 0 && (threshold == 0 || threshold > guardians.length)) revert InvalidConfig();
        owner = _owner;
        for (uint256 i; i < guardians.length; ++i) {
            if (guardians[i] == address(0) || guardians[i] == _owner || isGuardian[guardians[i]]) revert InvalidConfig();
            isGuardian[guardians[i]] = true;
            emit GuardianSet(guardians[i], true);
        }
        guardianCount = guardians.length;
        guardianThreshold = threshold;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // Ejecución
    // ------------------------------------------------------------------

    /// @notice Ejecuta una llamada. Owner: sin restricciones. Operador: con límites.
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        _authorize(target, value);
        ret = _call(0, target, value, data);
    }

    /// @notice Ejecuta varias llamadas de forma atómica (si una falla, revierte todo).
    function executeBatch(Call[] calldata calls) external {
        for (uint256 i; i < calls.length; ++i) {
            _authorize(calls[i].target, calls[i].value);
            _call(i, calls[i].target, calls[i].value, calls[i].data);
        }
    }

    // ------------------------------------------------------------------
    // Administración (solo owner)
    // ------------------------------------------------------------------

    /// @notice Alta/baja/modificación de operador.
    function setOperator(address op, bool enabled, uint128 dailyLimit) external onlyOwner {
        Operator storage o = operators[op];
        o.enabled = enabled;
        o.dailyLimit = dailyLimit;
        emit OperatorSet(op, enabled, dailyLimit);
    }

    /// @notice Permite o prohíbe que un operador llame a `target`.
    function setAllowedTarget(address op, address target, bool allowed) external onlyOwner {
        if (target == address(this)) revert OperatorCannotCallSelf();
        allowedTarget[op][target] = allowed;
        emit TargetAllowed(op, target, allowed);
    }

    /// @notice Alta/baja de guardián. Cancela cualquier recuperación en curso.
    function setGuardian(address g, bool active, uint256 newThreshold) external onlyOwner {
        if (g == address(0) || g == owner) revert InvalidConfig();
        if (isGuardian[g] != active) {
            isGuardian[g] = active;
            guardianCount = active ? guardianCount + 1 : guardianCount - 1;
            emit GuardianSet(g, active);
        }
        if (guardianCount > 0 && (newThreshold == 0 || newThreshold > guardianCount)) revert InvalidConfig();
        guardianThreshold = newThreshold;
        _cancelRecovery();
    }

    /// @notice Transferencia directa de ownership por el owner.
    function transferOwnership(address newOwner) external onlyOwner {
        _setOwner(newOwner);
    }

    // ------------------------------------------------------------------
    // Recuperación social
    // ------------------------------------------------------------------

    /// @notice Un guardián propone un nuevo owner (cuenta como su aprobación).
    function proposeRecovery(address newOwner) external {
        if (!isGuardian[msg.sender]) revert Unauthorized();
        if (newOwner == address(0)) revert InvalidConfig();
        uint32 round = recovery.round + 1;
        recovery = Recovery({newOwner: newOwner, executeAfter: uint64(block.timestamp + RECOVERY_DELAY), approvals: 0, round: round});
        emit RecoveryProposed(newOwner, recovery.executeAfter);
        _approve(round);
    }

    /// @notice Otro guardián aprueba la propuesta vigente.
    function approveRecovery() external {
        if (!isGuardian[msg.sender]) revert Unauthorized();
        if (recovery.newOwner == address(0)) revert NoRecovery();
        _approve(recovery.round);
    }

    /// @notice Aplica la recuperación cuando hay umbral y pasó el retraso. Cualquiera puede llamarla.
    function executeRecovery() external {
        Recovery memory r = recovery;
        if (r.newOwner == address(0)) revert NoRecovery();
        if (r.approvals < guardianThreshold || block.timestamp < r.executeAfter) revert RecoveryNotReady();
        recovery.newOwner = address(0);
        _setOwner(r.newOwner);
    }

    /// @notice El owner (si todavía tiene su clave) cancela una recuperación hostil.
    function cancelRecovery() external onlyOwner {
        _cancelRecovery();
    }

    // ------------------------------------------------------------------
    // EIP-1271
    // ------------------------------------------------------------------

    /// @notice Una firma es válida para la wallet si la firmó el owner actual.
    /// @dev Se envuelve el hash con la dirección de la wallet y el chainid para que
    ///      una firma del owner para ESTA wallet no sirva en otra wallet del mismo
    ///      owner ni en otra cadena (anti-replay).
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        bytes32 wrapped = keccak256(abi.encode(hash, address(this), block.chainid));
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(wrapped, signature);
        if (err == ECDSA.RecoverError.NoError && rec == owner) return MAGICVALUE;
        return 0xffffffff;
    }

    /// @notice Hash que el owner debe firmar para `isValidSignature`.
    function wrapHash(bytes32 hash) external view returns (bytes32) {
        return keccak256(abi.encode(hash, address(this), block.chainid));
    }

    /// @notice Cuánto le queda a un operador hoy.
    function remainingToday(address op) public view returns (uint256) {
        Operator memory o = operators[op];
        if (!o.enabled) return 0;
        if (o.day != block.timestamp / 1 days) return o.dailyLimit;
        return o.dailyLimit - o.spentToday;
    }

    // ------------------------------------------------------------------
    // Internas
    // ------------------------------------------------------------------

    /// @dev Autoriza según quién llama.
    function _authorize(address target, uint256 value) internal {
        if (msg.sender == owner) return; // owner: todo permitido
        Operator storage o = operators[msg.sender];
        if (!o.enabled) revert Unauthorized();
        // Un operador nunca puede llamar a la propia wallet (no puede auto-ascenderse).
        if (target == address(this) || !allowedTarget[msg.sender][target]) revert TargetNotAllowed(target);
        uint64 today = uint64(block.timestamp / 1 days);
        if (o.day != today) {
            o.day = today;
            o.spentToday = 0;
        }
        uint256 available = o.dailyLimit - o.spentToday;
        if (value > available) revert DailyLimitExceeded(value, available);
        o.spentToday += uint128(value);
    }

    function _call(uint256 i, address target, uint256 value, bytes calldata data) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(i, ret);
        emit Executed(msg.sender, target, value, data);
    }

    function _approve(uint32 round) internal {
        if (approvedRecovery[round][msg.sender]) revert AlreadyApproved();
        approvedRecovery[round][msg.sender] = true;
        recovery.approvals += 1;
        emit RecoveryApproved(msg.sender, recovery.approvals);
    }

    function _cancelRecovery() internal {
        if (recovery.newOwner != address(0)) {
            recovery.newOwner = address(0);
            emit RecoveryCancelled();
        }
    }

    function _setOwner(address newOwner) internal {
        if (newOwner == address(0) || isGuardian[newOwner]) revert InvalidConfig();
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }
}
