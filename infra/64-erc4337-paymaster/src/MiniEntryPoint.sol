// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UserOperation, IAccount, IPaymaster, PostOpMode, ValidationData} from "./UserOperation.sol";

/// @title MiniEntryPoint — EntryPoint ERC-4337 simplificado (mock didáctico)
/// @notice Implementa el núcleo del flujo oficial:
///   1. Validación: nonce, `validateUserOp` de la cuenta, `validatePaymasterUserOp`.
///   2. Prefondo: se reserva el costo máximo del depósito del pagador.
///   3. Ejecución: `call` a la cuenta con `callData` (si falla, la UserOp NO revierte
///      el bundle; se cobra igual el gas, como en el EntryPoint real).
///   4. `postOp` del paymaster con el costo real y reembolso del sobrante.
///   5. Pago al `beneficiary` (bundler).
/// @dev Simplificaciones respecto del EntryPoint v0.6 oficial:
///   - No soporta `initCode` (despliegue de cuentas) ni agregadores de firmas.
///   - Nonce secuencial simple por cuenta (sin "keys" de 192 bits).
///   - No impone las reglas de simulación ERC-7562 (eso lo hace el bundler off-chain).
///   - El precio de gas usado es `min(maxFeePerGas, maxPriorityFeePerGas + basefee)`.
contract MiniEntryPoint {
    using ValidationData for uint256;

    /// @notice Depósitos para pagar gas (cuentas y paymasters).
    mapping(address => uint256) public balanceOf;
    /// @notice Nonce por cuenta.
    mapping(address => uint256) public nonces;
    /// @dev Bandera anti-reentrada en handleOps.
    bool private _inHandleOps;

    event Deposited(address indexed account, uint256 total);
    event Withdrawn(address indexed account, address to, uint256 amount);
    event UserOperationEvent(
        bytes32 indexed userOpHash, address indexed sender, address indexed paymaster, uint256 nonce, bool success, uint256 actualGasCost
    );
    event UserOperationRevertReason(bytes32 indexed userOpHash, address indexed sender, bytes revertReason);

    /// @notice Error con índice de op (igual al oficial) para que el bundler la descarte.
    error FailedOp(uint256 opIndex, string reason);
    error Reentrancy();

    // ------------------------------------------------------------------
    // Depósitos
    // ------------------------------------------------------------------

    /// @notice Deposita ETH a nombre de `account` (paymaster o cuenta).
    function depositTo(address account) public payable {
        balanceOf[account] += msg.value;
        emit Deposited(account, balanceOf[account]);
    }

    /// @notice Retira depósito propio.
    function withdrawTo(address payable to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(msg.sender, to, amount);
    }

    receive() external payable {
        depositTo(msg.sender);
    }

    /// @notice Nonce esperado para la próxima UserOp de `sender`.
    function getNonce(address sender) external view returns (uint256) {
        return nonces[sender];
    }

    // ------------------------------------------------------------------
    // Hash
    // ------------------------------------------------------------------

    /// @notice Hash de la UserOp que la cuenta firma: incluye EntryPoint y chainid (anti-replay).
    function getUserOpHash(UserOperation calldata op) public view returns (bytes32) {
        bytes32 inner = keccak256(
            abi.encode(
                op.sender,
                op.nonce,
                keccak256(op.initCode),
                keccak256(op.callData),
                op.callGasLimit,
                op.verificationGasLimit,
                op.preVerificationGas,
                op.maxFeePerGas,
                op.maxPriorityFeePerGas,
                keccak256(op.paymasterAndData)
            )
        );
        return keccak256(abi.encode(inner, address(this), block.chainid));
    }

    // ------------------------------------------------------------------
    // handleOps
    // ------------------------------------------------------------------

    /// @notice Procesa un lote de UserOps. Llamado por el bundler.
    /// @param ops Operaciones.
    /// @param beneficiary Quien recibe el pago del gas (el bundler).
    function handleOps(UserOperation[] calldata ops, address payable beneficiary) external {
        if (_inHandleOps) revert Reentrancy();
        _inHandleOps = true;
        uint256 collected;
        for (uint256 i; i < ops.length; ++i) {
            collected += _handleOp(i, ops[i]);
        }
        _inHandleOps = false;
        (bool ok,) = beneficiary.call{value: collected}("");
        require(ok, "beneficiary payment failed");
    }

    /// @dev Procesa una UserOp y devuelve el costo cobrado.
    function _handleOp(uint256 i, UserOperation calldata op) internal returns (uint256 actualGasCost) {
        uint256 preGas = gasleft();
        if (op.initCode.length != 0) revert FailedOp(i, "AA00 initCode no soportado");
        bytes32 h = getUserOpHash(op);

        // ---- nonce ----
        if (op.nonce != nonces[op.sender]++) revert FailedOp(i, "AA25 invalid account nonce");

        uint256 gasPrice = _gasPrice(op);
        uint256 maxCost = (op.callGasLimit + op.verificationGasLimit * 3 + op.preVerificationGas) * gasPrice;
        address paymaster = op.paymasterAndData.length >= 20 ? address(bytes20(op.paymasterAndData[:20])) : address(0);

        // ---- validación de la cuenta ----
        uint256 missing;
        if (paymaster == address(0)) {
            uint256 bal = balanceOf[op.sender];
            missing = bal >= maxCost ? 0 : maxCost - bal;
        }
        uint256 accData;
        try IAccount(op.sender).validateUserOp{gas: op.verificationGasLimit}(op, h, missing) returns (uint256 d) {
            accData = d;
        } catch {
            revert FailedOp(i, "AA23 reverted");
        }
        _checkValidation(i, accData, "AA24 signature error", "AA22 expired or not due");

        // ---- validación del paymaster / prefondo ----
        bytes memory context;
        address payer = paymaster == address(0) ? op.sender : paymaster;
        if (balanceOf[payer] < maxCost) {
            revert FailedOp(i, paymaster == address(0) ? "AA21 didn't pay prefund" : "AA31 paymaster deposit too low");
        }
        balanceOf[payer] -= maxCost; // reserva
        if (paymaster != address(0)) {
            uint256 pmData;
            try IPaymaster(paymaster).validatePaymasterUserOp{gas: op.verificationGasLimit}(op, h, maxCost) returns (
                bytes memory c, uint256 d
            ) {
                context = c;
                pmData = d;
            } catch {
                revert FailedOp(i, "AA33 reverted");
            }
            _checkValidation(i, pmData, "AA34 signature error", "AA32 paymaster expired or not due");
        }

        // ---- ejecución ----
        bool success;
        {
            bytes memory ret;
            (success, ret) = op.sender.call{gas: op.callGasLimit}(op.callData);
            if (!success) emit UserOperationRevertReason(h, op.sender, ret);
        }

        // ---- contabilidad ----
        uint256 gasUsed = preGas - gasleft() + op.preVerificationGas;
        actualGasCost = gasUsed * gasPrice;
        if (paymaster != address(0) && context.length > 0) {
            // postOp se llama con el costo real; si revierte, en el oficial se reintenta
            // con opReverted. Acá simplificamos: si postOp revierte, toda la op falla.
            IPaymaster(paymaster).postOp(success ? PostOpMode.opSucceeded : PostOpMode.opReverted, context, actualGasCost);
            actualGasCost = (preGas - gasleft() + op.preVerificationGas) * gasPrice;
        }
        if (actualGasCost > maxCost) actualGasCost = maxCost;
        balanceOf[payer] += maxCost - actualGasCost; // reembolso del sobrante
        emit UserOperationEvent(h, op.sender, paymaster, op.nonce, success, actualGasCost);
    }

    /// @dev Verifica firma y ventana temporal de un validationData.
    function _checkValidation(uint256 i, uint256 data, string memory sigErr, string memory timeErr) internal view {
        (bool sigFailed, uint48 until, uint48 afterTs) = data.unpack();
        if (sigFailed) revert FailedOp(i, sigErr);
        if (block.timestamp > until || block.timestamp < afterTs) revert FailedOp(i, timeErr);
    }

    /// @dev Precio de gas efectivo (EIP-1559).
    function _gasPrice(UserOperation calldata op) internal view returns (uint256) {
        uint256 p = op.maxPriorityFeePerGas + block.basefee;
        return p < op.maxFeePerGas ? p : op.maxFeePerGas;
    }
}
