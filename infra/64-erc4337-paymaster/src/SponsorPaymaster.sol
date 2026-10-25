// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UserOperation, IPaymaster, PostOpMode, ValidationData} from "./UserOperation.sol";
import {MiniEntryPoint} from "./MiniEntryPoint.sol";

/// @title SponsorPaymaster — Paymaster que patrocina gas con firma del backend
/// @notice Modelo "verifying paymaster": un servicio off-chain (el `signer`) decide
///         a quién patrocinar (ej.: usuarios nuevos de una dApp) y firma un permiso
///         con ventana de validez. Además, on-chain se aplica un **presupuesto de gas
///         por cuenta** para que un signer comprometido no pueda drenar todo el depósito.
/// @dev `paymasterAndData` = [20 bytes paymaster][abi.encode(uint48 validUntil, uint48 validAfter)][65 bytes firma]
///      La firma cubre los campos de la UserOp SIN `paymasterAndData` ni `signature`
///      (porque esos campos contienen la propia firma), más chainid y dirección del paymaster.
contract SponsorPaymaster is IPaymaster, Ownable {
    using ValidationData for uint256;

    MiniEntryPoint public immutable entryPoint;
    /// @notice Firmante off-chain autorizado.
    address public signer;
    /// @notice Presupuesto máximo de gas (en wei) por cuenta.
    uint256 public budgetPerAccount;
    /// @notice Gastado por cuenta.
    mapping(address => uint256) public spent;

    uint256 private constant DATA_OFFSET = 20;
    uint256 private constant SIG_OFFSET = 84; // 20 + 64

    event Sponsored(address indexed account, uint256 actualGasCost);

    error NotEntryPoint();
    error BudgetExceeded();
    error BadPaymasterData();

    constructor(MiniEntryPoint ep, address _signer, uint256 _budget) Ownable(msg.sender) {
        entryPoint = ep;
        signer = _signer;
        budgetPerAccount = _budget;
    }

    /// @notice Cambia el firmante (rotación de clave).
    function setSigner(address s) external onlyOwner { signer = s; }
    /// @notice Cambia el presupuesto por cuenta.
    function setBudget(uint256 b) external onlyOwner { budgetPerAccount = b; }

    /// @notice Deposita ETH en el EntryPoint para pagar gas.
    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /// @notice Retira depósito (solo owner).
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
    }

    /// @notice Hash que firma el backend.
    function getHash(UserOperation calldata op, uint48 validUntil, uint48 validAfter) public view returns (bytes32) {
        return keccak256(
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
                block.chainid,
                address(this),
                validUntil,
                validAfter
            )
        );
    }

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(UserOperation calldata op, bytes32, uint256 maxCost)
        external
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        if (op.paymasterAndData.length != SIG_OFFSET + 65) revert BadPaymasterData();
        (uint48 validUntil, uint48 validAfter) = abi.decode(op.paymasterAndData[DATA_OFFSET:SIG_OFFSET], (uint48, uint48));
        bytes calldata sig = op.paymasterAndData[SIG_OFFSET:];

        // Presupuesto on-chain: protege el depósito aunque el signer firme de más.
        if (spent[op.sender] + maxCost > budgetPerAccount) revert BudgetExceeded();

        bytes32 h = MessageHashUtils.toEthSignedMessageHash(getHash(op, validUntil, validAfter));
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(h, sig);
        bool sigFailed = err != ECDSA.RecoverError.NoError || rec != signer;
        // El contexto le pasa a postOp quién es la cuenta para contabilizar el gasto.
        context = abi.encode(op.sender);
        validationData = ValidationData.pack(sigFailed, validUntil, validAfter);
    }

    /// @inheritdoc IPaymaster
    /// @dev Se cobra el costo real aunque la ejecución haya revertido (el gas se gastó igual).
    function postOp(PostOpMode, bytes calldata context, uint256 actualGasCost) external override {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint();
        address account = abi.decode(context, (address));
        spent[account] += actualGasCost;
        emit Sponsored(account, actualGasCost);
    }
}
