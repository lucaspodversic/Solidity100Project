// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation, IAccount, ValidationData} from "./UserOperation.sol";
import {MiniEntryPoint} from "./MiniEntryPoint.sol";

/// @title SessionKeyAccount — Cuenta ERC-4337 con owner ECDSA y *session keys*
/// @notice Una session key es una clave temporal (p. ej. generada en el navegador
///         para un juego) que puede firmar UserOps **limitadas**:
///           - solo dentro de [validAfter, validUntil],
///           - solo hacia UN contrato destino (`target`),
///           - solo con ciertos selectores (opcional) y
///           - con un tope de ETH por operación (`maxValuePerOp`).
///         Así el usuario no firma con su clave principal cada acción, y si la
///         session key se filtra el daño queda acotado.
/// @dev Formato de `signature`:
///        - 65 bytes  => firma del owner sobre `toEthSignedMessageHash(userOpHash)`.
///        - 85 bytes  => [20 bytes dirección de session key][65 bytes firma de la session key].
contract SessionKeyAccount is IAccount {
    using ValidationData for uint256;

    /// @notice Permisos de una session key.
    struct Session {
        uint48 validAfter;
        uint48 validUntil;
        address target;
        uint128 maxValuePerOp;
        bool revoked;
    }

    MiniEntryPoint public immutable entryPoint;
    address public owner;
    mapping(address => Session) public sessions;
    /// @notice sessionKey => selector => permitido (si no hay ninguno marcado, cualquiera).
    mapping(address => mapping(bytes4 => bool)) public allowedSelector;
    mapping(address => bool) public restrictSelectors;

    event SessionAdded(address indexed key, address target, uint48 validUntil);
    event SessionRevoked(address indexed key);

    error NotEntryPointOrOwner();
    error NotOwner();
    error CallFailed(bytes);

    uint256 internal constant SIG_FAILED = 1;

    constructor(MiniEntryPoint ep, address _owner) {
        entryPoint = ep;
        owner = _owner;
    }

    receive() external payable {}

    /// @dev Las ejecuciones vienen del EntryPoint (UserOps) o directo del owner.
    modifier onlyEntryPointOrOwner() {
        if (msg.sender != address(entryPoint) && msg.sender != owner) revert NotEntryPointOrOwner();
        _;
    }

    /// @dev Administración: owner directo o la propia cuenta (vía UserOp firmada por owner).
    modifier onlySelfOrOwner() {
        if (msg.sender != owner && msg.sender != address(this)) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------
    // Ejecución
    // ------------------------------------------------------------------

    /// @notice Ejecuta una llamada desde la cuenta.
    function execute(address target, uint256 value, bytes calldata data) external onlyEntryPointOrOwner {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(ret);
    }

    // ------------------------------------------------------------------
    // Session keys
    // ------------------------------------------------------------------

    /// @notice Registra una session key.
    function addSession(address key, address target, uint48 validAfter, uint48 validUntil, uint128 maxValuePerOp, bytes4[] calldata selectors)
        external
        onlySelfOrOwner
    {
        sessions[key] = Session(validAfter, validUntil, target, maxValuePerOp, false);
        restrictSelectors[key] = selectors.length > 0;
        for (uint256 i; i < selectors.length; ++i) allowedSelector[key][selectors[i]] = true;
        emit SessionAdded(key, target, validUntil);
    }

    /// @notice Revoca una session key inmediatamente.
    function revokeSession(address key) external onlySelfOrOwner {
        sessions[key].revoked = true;
        emit SessionRevoked(key);
    }

    // ------------------------------------------------------------------
    // ERC-4337
    // ------------------------------------------------------------------

    /// @inheritdoc IAccount
    /// @dev IMPORTANTE: nunca revertir por firma inválida, sino devolver SIG_FAILED
    ///      (así el bundler puede simular sin errores). Sí se revierte si el
    ///      llamador no es el EntryPoint.
    function validateUserOp(UserOperation calldata op, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        override
        returns (uint256 validationData)
    {
        require(msg.sender == address(entryPoint), "solo EntryPoint");
        validationData = _validateSignature(op, userOpHash);
        // Pagar el prefondo que falta (si no hay paymaster).
        if (missingAccountFunds > 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            (ok); // si falla, el EntryPoint lo detecta por falta de depósito
        }
    }

    /// @dev Lógica de firma (owner o session key).
    function _validateSignature(UserOperation calldata op, bytes32 userOpHash) internal view returns (uint256) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        if (op.signature.length == 65) {
            (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(ethHash, op.signature);
            return (err == ECDSA.RecoverError.NoError && rec == owner) ? 0 : SIG_FAILED;
        }
        if (op.signature.length != 85) return SIG_FAILED;

        address key = address(bytes20(op.signature[:20]));
        Session memory s = sessions[key];
        if (s.target == address(0) || s.revoked) return SIG_FAILED;
        (address r, ECDSA.RecoverError e,) = ECDSA.tryRecover(ethHash, op.signature[20:]);
        if (e != ECDSA.RecoverError.NoError || r != key) return SIG_FAILED;

        // La session key SOLO puede llamar `execute(target, value, data)` con su destino.
        if (op.callData.length < 4 || bytes4(op.callData[:4]) != this.execute.selector) return SIG_FAILED;
        (address target, uint256 value, bytes memory data) = abi.decode(op.callData[4:], (address, uint256, bytes));
        if (target != s.target || value > s.maxValuePerOp) return SIG_FAILED;
        if (restrictSelectors[key]) {
            if (data.length < 4) return SIG_FAILED;
            bytes4 sel;
            assembly {
                sel := mload(add(data, 32))
            }
            if (!allowedSelector[key][sel]) return SIG_FAILED;
        }
        // La ventana temporal la verifica el EntryPoint con validationData.
        return ValidationData.pack(false, s.validUntil, s.validAfter);
    }
}
