// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Estructuras e interfaces de ERC-4337 (versión didáctica, formato v0.6)
/// @notice ERC-4337 implementa "account abstraction" SIN cambiar el protocolo:
///   - El usuario firma una `UserOperation` (no una transacción).
///   - Un *bundler* junta UserOps y llama `EntryPoint.handleOps` (paga el gas en ETH).
///   - El `EntryPoint` pide a cada cuenta que valide su UserOp (`validateUserOp`),
///     opcionalmente pide a un *Paymaster* que acepte pagar (`validatePaymasterUserOp`),
///     ejecuta la llamada y cobra el gas al depósito de la cuenta o del paymaster.
/// @dev Usamos el formato v0.6 (campos sin empaquetar) porque es más legible.

/// @notice Operación de usuario.
struct UserOperation {
    address sender;               // la cuenta inteligente
    uint256 nonce;                // anti-replay (gestionado por el EntryPoint)
    bytes initCode;               // (no soportado en este mock: cuentas ya desplegadas)
    bytes callData;               // llamada que el EntryPoint hará a `sender`
    uint256 callGasLimit;         // gas para la ejecución
    uint256 verificationGasLimit; // gas para validar
    uint256 preVerificationGas;   // compensación al bundler por calldata/overhead
    uint256 maxFeePerGas;         // precio máximo por gas
    uint256 maxPriorityFeePerGas; // propina máxima
    bytes paymasterAndData;       // [20 bytes paymaster][datos del paymaster]
    bytes signature;              // firma (formato definido por la cuenta)
}

/// @notice Interfaz que debe implementar una cuenta ERC-4337.
interface IAccount {
    /// @return validationData empaquetado: [aggregator/sigFail:160][validUntil:48][validAfter:48]
    ///         (sigFail = 1 en los 160 bits bajos indica firma inválida).
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        returns (uint256 validationData);
}

/// @notice Modo de postOp.
enum PostOpMode {
    opSucceeded,
    opReverted
}

/// @notice Interfaz de un Paymaster.
interface IPaymaster {
    function validatePaymasterUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData);

    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost) external;
}

/// @notice Utilidades para (des)empaquetar `validationData`.
library ValidationData {
    /// @notice Empaqueta (sigFailed, validUntil, validAfter).
    function pack(bool sigFailed, uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return (sigFailed ? 1 : 0) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }

    /// @notice Desempaqueta. `validUntil == 0` significa "sin vencimiento".
    function unpack(uint256 d) internal pure returns (bool sigFailed, uint48 validUntil, uint48 validAfter) {
        sigFailed = uint160(d) != 0;
        validUntil = uint48(d >> 160);
        validAfter = uint48(d >> 208);
        if (validUntil == 0) validUntil = type(uint48).max;
    }
}
