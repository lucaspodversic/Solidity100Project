// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MultiSigWallet — Billetera multifirma con umbral configurable
/// @author Proyecto 58 de "100 proyectos Solidity"
/// @notice Un conjunto de `owners` propone transacciones; cuando una transacción
///         junta al menos `threshold` confirmaciones, cualquier owner puede ejecutarla.
/// @dev Diseño inspirado en la clásica MultiSigWallet de Gnosis, simplificado y
///      modernizado (errores personalizados, CEI, guarda de reentrada propia).
///      La administración (agregar/quitar owners, cambiar umbral) SOLO se puede
///      hacer mediante una transacción multifirma dirigida a la propia wallet
///      (`onlyWallet`), de modo que ningún owner individual tiene privilegios extra.
contract MultiSigWallet {
    // ---------------------------------------------------------------------
    // Tipos
    // ---------------------------------------------------------------------

    /// @notice Representa una transacción propuesta.
    /// @param to Destino de la llamada.
    /// @param value Cantidad de wei a enviar.
    /// @param data Calldata a enviar (vacío para transferencias simples de ETH).
    /// @param executed Si ya fue ejecutada (evita doble ejecución).
    /// @param numConfirmations Contador de confirmaciones vigentes.
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 numConfirmations;
    }

    // ---------------------------------------------------------------------
    // Constantes y almacenamiento
    // ---------------------------------------------------------------------

    /// @notice Límite superior de owners para acotar el gas de los bucles.
    uint256 public constant MAX_OWNERS = 50;

    /// @notice Lista de owners (en orden de alta).
    address[] public owners;
    /// @notice Acceso O(1) para saber si una dirección es owner.
    mapping(address => bool) public isOwner;
    /// @notice Cantidad mínima de confirmaciones necesarias para ejecutar.
    uint256 public threshold;
    /// @notice Todas las transacciones propuestas (el índice es el id).
    Transaction[] public transactions;
    /// @notice txId => owner => confirmó?
    mapping(uint256 => mapping(address => bool)) public isConfirmed;
    /// @notice "Época" de owners: se incrementa al cambiar el set de owners para
    ///         invalidar confirmaciones de owners removidos (ver `_confirmationsValid`).
    uint256 public ownersNonce;
    /// @dev Bandera simple anti-reentrada (1 = libre, 2 = ocupado).
    uint256 private _lock = 1;

    // ---------------------------------------------------------------------
    // Eventos
    // ---------------------------------------------------------------------

    event Deposit(address indexed sender, uint256 amount, uint256 balance);
    event SubmitTransaction(address indexed owner, uint256 indexed txId, address indexed to, uint256 value, bytes data);
    event ConfirmTransaction(address indexed owner, uint256 indexed txId);
    event RevokeConfirmation(address indexed owner, uint256 indexed txId);
    event ExecuteTransaction(address indexed owner, uint256 indexed txId);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 threshold);

    // ---------------------------------------------------------------------
    // Errores personalizados (más baratos en gas que los strings de require)
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotWallet();
    error TxDoesNotExist();
    error TxAlreadyExecuted();
    error TxAlreadyConfirmed();
    error TxNotConfirmed();
    error NotEnoughConfirmations(uint256 have, uint256 need);
    error InvalidOwner();
    error DuplicateOwner();
    error InvalidThreshold();
    error TooManyOwners();
    error CallFailed(bytes returndata);
    error Reentrancy();

    // ---------------------------------------------------------------------
    // Modificadores
    // ---------------------------------------------------------------------

    /// @dev Restringe a owners actuales.
    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    /// @dev Restringe a llamadas hechas por la propia wallet (o sea, aprobadas por multifirma).
    modifier onlyWallet() {
        if (msg.sender != address(this)) revert NotWallet();
        _;
    }

    /// @dev Verifica que el id de transacción exista.
    modifier txExists(uint256 txId) {
        if (txId >= transactions.length) revert TxDoesNotExist();
        _;
    }

    /// @dev Verifica que la transacción no se haya ejecutado.
    modifier notExecuted(uint256 txId) {
        if (transactions[txId].executed) revert TxAlreadyExecuted();
        _;
    }

    /// @dev Guarda anti-reentrada mínima.
    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param _owners Lista inicial de owners (sin duplicados ni address(0)).
    /// @param _threshold Umbral de confirmaciones (1 <= umbral <= owners.length).
    constructor(address[] memory _owners, uint256 _threshold) {
        if (_owners.length == 0 || _owners.length > MAX_OWNERS) revert TooManyOwners();
        if (_threshold == 0 || _threshold > _owners.length) revert InvalidThreshold();
        for (uint256 i = 0; i < _owners.length; i++) {
            _addOwner(_owners[i]);
        }
        threshold = _threshold;
        emit ThresholdChanged(_threshold);
    }

    /// @notice Permite recibir ETH directamente (depósitos).
    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    // ---------------------------------------------------------------------
    // Flujo de transacciones
    // ---------------------------------------------------------------------

    /// @notice Propone una nueva transacción. El proponente la confirma automáticamente.
    /// @return txId Identificador de la transacción creada.
    function submitTransaction(address to, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (uint256 txId)
    {
        txId = transactions.length;
        transactions.push(Transaction({to: to, value: value, data: data, executed: false, numConfirmations: 0}));
        emit SubmitTransaction(msg.sender, txId, to, value, data);
        _confirm(txId); // el proponente confirma de una (ahorra una tx)
    }

    /// @notice Confirma una transacción pendiente.
    function confirmTransaction(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        _confirm(txId);
    }

    /// @notice Revoca una confirmación previa (si todavía no se ejecutó).
    function revokeConfirmation(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        if (!isConfirmed[txId][msg.sender]) revert TxNotConfirmed();
        isConfirmed[txId][msg.sender] = false;
        transactions[txId].numConfirmations -= 1;
        emit RevokeConfirmation(msg.sender, txId);
    }

    /// @notice Ejecuta una transacción que alcanzó el umbral.
    /// @dev Patrón Checks-Effects-Interactions: marcamos `executed = true` ANTES
    ///      de la llamada externa, y además hay guarda `nonReentrant`.
    ///      Si la llamada falla, todo revierte (incluido `executed`), así la
    ///      transacción puede reintentarse más tarde.
    function executeTransaction(uint256 txId)
        external
        onlyOwner
        txExists(txId)
        notExecuted(txId)
        nonReentrant
    {
        Transaction storage txn = transactions[txId];
        // Recontamos con los owners ACTUALES: si un owner fue removido, su
        // confirmación deja de contar (defensa ante cambios de set de owners).
        uint256 valid = _validConfirmations(txId);
        if (valid < threshold) revert NotEnoughConfirmations(valid, threshold);

        txn.executed = true; // Efecto antes de la interacción

        (bool ok, bytes memory ret) = txn.to.call{value: txn.value}(txn.data);
        if (!ok) revert CallFailed(ret);

        emit ExecuteTransaction(msg.sender, txId);
    }

    // ---------------------------------------------------------------------
    // Administración (solo vía multifirma)
    // ---------------------------------------------------------------------

    /// @notice Agrega un owner. Debe llamarse a través de `executeTransaction`.
    function addOwner(address owner) external onlyWallet {
        if (owners.length + 1 > MAX_OWNERS) revert TooManyOwners();
        _addOwner(owner);
        ownersNonce++;
    }

    /// @notice Quita un owner. Si el umbral queda mayor que la cantidad de owners, se ajusta.
    function removeOwner(address owner) external onlyWallet {
        if (!isOwner[owner]) revert InvalidOwner();
        if (owners.length == 1) revert InvalidThreshold(); // nunca dejar la wallet sin owners
        isOwner[owner] = false;
        // Borrado "swap & pop" O(n) para no dejar huecos en el array.
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        if (threshold > owners.length) {
            threshold = owners.length;
            emit ThresholdChanged(threshold);
        }
        ownersNonce++;
        emit OwnerRemoved(owner);
    }

    /// @notice Cambia el umbral de confirmaciones.
    function changeThreshold(uint256 newThreshold) external onlyWallet {
        if (newThreshold == 0 || newThreshold > owners.length) revert InvalidThreshold();
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }

    // ---------------------------------------------------------------------
    // Lectura
    // ---------------------------------------------------------------------

    /// @notice Devuelve todos los owners.
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /// @notice Cantidad de transacciones propuestas.
    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    /// @notice Devuelve una transacción completa.
    function getTransaction(uint256 txId)
        external
        view
        txExists(txId)
        returns (address to, uint256 value, bytes memory data, bool executed, uint256 numConfirmations)
    {
        Transaction storage t = transactions[txId];
        return (t.to, t.value, t.data, t.executed, t.numConfirmations);
    }

    /// @notice Confirmaciones que cuentan HOY (solo de owners vigentes).
    function validConfirmations(uint256 txId) external view txExists(txId) returns (uint256) {
        return _validConfirmations(txId);
    }

    // ---------------------------------------------------------------------
    // Internas
    // ---------------------------------------------------------------------

    /// @dev Registra la confirmación de `msg.sender`.
    function _confirm(uint256 txId) internal {
        if (isConfirmed[txId][msg.sender]) revert TxAlreadyConfirmed();
        isConfirmed[txId][msg.sender] = true;
        transactions[txId].numConfirmations += 1;
        emit ConfirmTransaction(msg.sender, txId);
    }

    /// @dev Cuenta confirmaciones de owners actuales (O(owners), acotado por MAX_OWNERS).
    function _validConfirmations(uint256 txId) internal view returns (uint256 count) {
        for (uint256 i = 0; i < owners.length; i++) {
            if (isConfirmed[txId][owners[i]]) count++;
        }
    }

    /// @dev Valida y agrega un owner.
    function _addOwner(address owner) internal {
        if (owner == address(0) || owner == address(this)) revert InvalidOwner();
        if (isOwner[owner]) revert DuplicateOwner();
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAdded(owner);
    }
}
