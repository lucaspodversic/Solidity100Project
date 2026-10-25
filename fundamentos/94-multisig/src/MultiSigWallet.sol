// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MultiSigWallet — billetera que requiere M de N aprobaciones
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #94
/// @notice Flujo: un dueño `submit` una transacción → los dueños `confirm` →
///         con `required` confirmaciones cualquiera de ellos la `execute`.
///         Un dueño puede `revoke` su confirmación mientras no se ejecutó.
/// @dev La propia billetera puede cambiar sus dueños/umbral SOLO mediante una
///      transacción multisig dirigida a sí misma (`onlySelf`). Así ningún
///      dueño individual puede tomar el control.
///      En producción preferí Safe (Gnosis Safe), auditada y con firmas off-chain.
contract MultiSigWallet {
    error NotOwner();
    error NotSelf();
    error InvalidRequirement(uint256 owners, uint256 required);
    error InvalidOwner(address owner);
    error TxNotFound(uint256 txId);
    error AlreadyExecuted(uint256 txId);
    error AlreadyConfirmed(uint256 txId);
    error NotConfirmed(uint256 txId);
    error NotEnoughConfirmations(uint256 have, uint256 need);
    error ExecutionFailed(bytes reason);

    event Deposit(address indexed sender, uint256 amount);
    event Submit(uint256 indexed txId, address indexed owner, address to, uint256 value, bytes data);
    event Confirm(uint256 indexed txId, address indexed owner);
    event Revoke(uint256 indexed txId, address indexed owner);
    event Execute(uint256 indexed txId);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event RequirementChanged(uint256 required);

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public required;
    Transaction[] public transactions;
    /// @notice txId => dueño => ¿confirmó?
    mapping(uint256 => mapping(address => bool)) public confirmed;

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    modifier txExists(uint256 txId) {
        if (txId >= transactions.length) revert TxNotFound(txId);
        _;
    }

    modifier notExecuted(uint256 txId) {
        if (transactions[txId].executed) revert AlreadyExecuted(txId);
        _;
    }

    /// @param owners_   Lista de dueños (sin repetidos ni address(0)).
    /// @param required_ Confirmaciones necesarias (1..owners.length).
    constructor(address[] memory owners_, uint256 required_) {
        if (required_ == 0 || required_ > owners_.length) revert InvalidRequirement(owners_.length, required_);
        for (uint256 i; i < owners_.length; ++i) {
            _addOwner(owners_[i]);
        }
        required = required_;
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    // --------------------------- flujo principal ---------------------------

    /// @notice Proponer una transacción (queda confirmada por quien la propone).
    function submit(address to, uint256 value, bytes calldata data) external onlyOwner returns (uint256 txId) {
        txId = transactions.length;
        transactions.push(Transaction(to, value, data, false, 0));
        emit Submit(txId, msg.sender, to, value, data);
        confirm(txId);
    }

    /// @notice Confirmar una transacción pendiente.
    function confirm(uint256 txId) public onlyOwner txExists(txId) notExecuted(txId) {
        if (confirmed[txId][msg.sender]) revert AlreadyConfirmed(txId);
        confirmed[txId][msg.sender] = true;
        transactions[txId].confirmations++;
        emit Confirm(txId, msg.sender);
    }

    /// @notice Retirar la confirmación propia.
    function revoke(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        if (!confirmed[txId][msg.sender]) revert NotConfirmed(txId);
        confirmed[txId][msg.sender] = false;
        transactions[txId].confirmations--;
        emit Revoke(txId, msg.sender);
    }

    /// @notice Ejecutar una transacción con suficientes confirmaciones.
    function execute(uint256 txId) external onlyOwner txExists(txId) notExecuted(txId) {
        Transaction storage t = transactions[txId];
        if (t.confirmations < required) revert NotEnoughConfirmations(t.confirmations, required);
        t.executed = true; // efecto antes de la llamada externa (anti-reentrancia)
        (bool ok, bytes memory ret) = t.to.call{value: t.value}(t.data);
        if (!ok) revert ExecutionFailed(ret);
        emit Execute(txId);
    }

    // ------------------- administración (solo vía multisig) -------------------

    function addOwner(address owner) external onlySelf {
        _addOwner(owner);
    }

    function removeOwner(address owner) external onlySelf {
        if (!isOwner[owner]) revert InvalidOwner(owner);
        if (owners.length - 1 < required) revert InvalidRequirement(owners.length - 1, required);
        isOwner[owner] = false;
        for (uint256 i; i < owners.length; ++i) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1]; // swap & pop: O(1) al borrar
                owners.pop();
                break;
            }
        }
        emit OwnerRemoved(owner);
    }

    function changeRequirement(uint256 required_) external onlySelf {
        if (required_ == 0 || required_ > owners.length) revert InvalidRequirement(owners.length, required_);
        required = required_;
        emit RequirementChanged(required_);
    }

    // ------------------------------- vistas -------------------------------

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function transactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function _addOwner(address owner) internal {
        if (owner == address(0) || isOwner[owner]) revert InvalidOwner(owner);
        isOwner[owner] = true;
        owners.push(owner);
        emit OwnerAdded(owner);
    }
}
