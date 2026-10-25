// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {LendingPool} from "./protocol/LendingPool.sol";
import {PriceOracle} from "./protocol/PriceOracle.sol";

/// @title DelegatedLendingPool — LendingPool + delegación de crédito (estilo Aave v2/v3)
/// @notice Un DELEGADOR con colateral puede autorizar a un DELEGADO a pedir prestado contra
///         su colateral sin transferírselo. La deuda queda registrada a nombre del delegador
///         (es su colateral el que respalda y el que puede ser liquidado); los fondos van al
///         delegado. Es crédito NO colateralizado para el delegado: la garantía es la confianza
///         (o un acuerdo off-chain / on-chain como `CreditAgreement`).
/// @dev  - `borrowAllowance[delegator][asset][delegatee]` = cuánto puede pedir el delegado.
///       - `approveDelegation` (tx del delegador) o `delegationWithSig` (firma EIP-712, gasless).
///       - `borrowOnBehalf` descuenta la allowance y verifica la salud del DELEGADOR.
contract DelegatedLendingPool is LendingPool, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant DELEGATION_TYPEHASH = keccak256(
        "Delegation(address delegator,address delegatee,address asset,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    mapping(address => mapping(address => mapping(address => uint256))) public borrowAllowance;
    mapping(address => uint256) public nonces;

    event BorrowAllowanceDelegated(address indexed delegator, address indexed delegatee, address asset, uint256 amount);
    event BorrowOnBehalf(address indexed asset, address indexed delegatee, address indexed delegator, uint256 amount);

    error InsufficientAllowance(uint256 allowance, uint256 requested);
    error ExpiredSignature();
    error InvalidSignature();

    constructor(PriceOracle _oracle, address _treasury)
        LendingPool(_oracle, _treasury)
        EIP712("DelegatedLendingPool", "1")
    {}

    /// @notice Fija (no suma) la allowance de crédito para `delegatee` en `asset`.
    /// @dev Fijar en vez de sumar evita ambigüedades; para revocar, pasar 0.
    function approveDelegation(address asset, address delegatee, uint256 amount) external {
        borrowAllowance[msg.sender][asset][delegatee] = amount;
        emit BorrowAllowanceDelegated(msg.sender, delegatee, asset, amount);
    }

    /// @notice Igual que approveDelegation pero con firma EIP-712 del delegador.
    /// @dev Protección contra replay: nonce por delegador + deadline + domain separator
    ///      (incluye chainId y la dirección del contrato).
    function delegationWithSig(
        address delegator,
        address delegatee,
        address asset,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert ExpiredSignature();
        bytes32 structHash =
            keccak256(abi.encode(DELEGATION_TYPEHASH, delegator, delegatee, asset, amount, nonces[delegator]++, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        if (signer != delegator) revert InvalidSignature();
        borrowAllowance[delegator][asset][delegatee] = amount;
        emit BorrowAllowanceDelegated(delegator, delegatee, asset, amount);
    }

    /// @notice El delegado pide prestado contra el colateral de `onBehalfOf`.
    /// @dev La deuda se suma al delegador; el chequeo de LTV es sobre su cuenta.
    function borrowOnBehalf(address asset, uint256 amount, address onBehalfOf) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (onBehalfOf != msg.sender) {
            uint256 allow = borrowAllowance[onBehalfOf][asset][msg.sender];
            if (allow < amount) revert InsufficientAllowance(allow, amount);
            if (allow != type(uint256).max) borrowAllowance[onBehalfOf][asset][msg.sender] = allow - amount;
        }
        _accrueAll();
        Market storage m = markets[asset];
        if (!m.listed) revert NotListed();
        if (amount > m.cash) revert InsufficientLiquidity();
        uint256 scaled = Math.mulDiv(amount, RAY, m.borrowIndex, Math.Rounding.Ceil);
        scaledBorrowOf[asset][onBehalfOf] += scaled;
        m.totalScaledBorrow += scaled;
        m.cash -= amount;
        (, uint256 debtUsd, uint256 borrowLimit,) = accountData(onBehalfOf);
        if (debtUsd > borrowLimit) revert InsufficientCollateral();
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit BorrowOnBehalf(asset, msg.sender, onBehalfOf, amount);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
