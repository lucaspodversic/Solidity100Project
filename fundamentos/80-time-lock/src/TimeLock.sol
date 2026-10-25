// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TimeLock — bóveda de ETH con bloqueo temporal y cola de operaciones
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #80
/// @notice Dos usos didácticos de `block.timestamp`:
///   1. **Depósitos bloqueados**: cada usuario deposita ETH que solo puede
///      retirar después de su `unlockTime` (que puede extender, nunca acortar).
///   2. **Operaciones con demora (queue/execute)**: el dueño encola una
///      llamada arbitraria que recién se puede ejecutar tras `MIN_DELAY`
///      y antes de que expire (`GRACE_PERIOD`). Así los usuarios ven con
///      anticipación qué va a hacer el admin (patrón de Compound Timelock).
/// @dev `block.timestamp` puede ser ajustado levemente por el proponente del
///      bloque (unos pocos segundos). Es aceptable para demoras de horas/días,
///      nunca para lógica que dependa de precisión de segundos.
contract TimeLock {
    error NotOwner();
    error StillLocked(uint256 ahora, uint256 desbloqueo);
    error CannotShortenLock();
    error NothingDeposited();
    error DelayTooShort();
    error AlreadyQueued(bytes32 id);
    error NotQueued(bytes32 id);
    error TooEarly(uint256 ahora, uint256 eta);
    error Expired(uint256 ahora, uint256 limite);
    error CallFailed(bytes data);
    error TransferFailed();

    event Deposited(address indexed user, uint256 amount, uint256 unlockTime);
    event LockExtended(address indexed user, uint256 newUnlockTime);
    event Withdrawn(address indexed user, uint256 amount);
    event Queued(bytes32 indexed id, address target, uint256 value, bytes data, uint256 eta);
    event Executed(bytes32 indexed id);
    event Cancelled(bytes32 indexed id);

    /// @notice Demora mínima entre encolar y ejecutar.
    uint256 public constant MIN_DELAY = 2 days;
    /// @notice Ventana después de `eta` en la que la operación sigue siendo válida.
    uint256 public constant GRACE_PERIOD = 14 days;

    address public immutable owner;

    /// @notice Saldo bloqueado por usuario.
    mapping(address => uint256) public balances;
    /// @notice Momento a partir del cual el usuario puede retirar.
    mapping(address => uint256) public unlockTime;
    /// @notice Operaciones encoladas (id => encolada).
    mapping(bytes32 => bool) public queued;

    constructor() {
        owner = msg.sender;
    }

    // ------------------------- Parte 1: depósitos -------------------------

    /// @notice Depositar ETH bloqueado `lockSeconds` desde ahora.
    /// @dev Si ya había un bloqueo más largo, se conserva el mayor.
    function deposit(uint256 lockSeconds) external payable {
        if (msg.value == 0) revert NothingDeposited();
        uint256 nuevo = block.timestamp + lockSeconds;
        if (nuevo > unlockTime[msg.sender]) unlockTime[msg.sender] = nuevo;
        balances[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value, unlockTime[msg.sender]);
    }

    /// @notice Extender (nunca acortar) el bloqueo propio.
    function extendLock(uint256 newUnlockTime) external {
        if (newUnlockTime <= unlockTime[msg.sender]) revert CannotShortenLock();
        unlockTime[msg.sender] = newUnlockTime;
        emit LockExtended(msg.sender, newUnlockTime);
    }

    /// @notice Retirar todo una vez vencido el bloqueo.
    function withdraw() external {
        uint256 t = unlockTime[msg.sender];
        if (block.timestamp < t) revert StillLocked(block.timestamp, t);
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingDeposited();
        balances[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ------------------- Parte 2: operaciones con demora -------------------

    /// @notice Identificador único de una operación.
    function getId(address target, uint256 value, bytes calldata data, uint256 eta) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, eta));
    }

    /// @notice El dueño encola una llamada para ejecutarse en `eta`.
    function queue(address target, uint256 value, bytes calldata data, uint256 eta) external returns (bytes32 id) {
        if (msg.sender != owner) revert NotOwner();
        if (eta < block.timestamp + MIN_DELAY) revert DelayTooShort();
        id = getId(target, value, data, eta);
        if (queued[id]) revert AlreadyQueued(id);
        queued[id] = true;
        emit Queued(id, target, value, data, eta);
    }

    /// @notice Ejecuta una operación encolada dentro de su ventana válida.
    function execute(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        payable
        returns (bytes memory result)
    {
        if (msg.sender != owner) revert NotOwner();
        bytes32 id = getId(target, value, data, eta);
        if (!queued[id]) revert NotQueued(id);
        if (block.timestamp < eta) revert TooEarly(block.timestamp, eta);
        if (block.timestamp > eta + GRACE_PERIOD) revert Expired(block.timestamp, eta + GRACE_PERIOD);
        queued[id] = false; // efecto antes de la llamada externa
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) revert CallFailed(result);
        emit Executed(id);
    }

    /// @notice Cancela una operación encolada.
    function cancel(bytes32 id) external {
        if (msg.sender != owner) revert NotOwner();
        if (!queued[id]) revert NotQueued(id);
        queued[id] = false;
        emit Cancelled(id);
    }
}
