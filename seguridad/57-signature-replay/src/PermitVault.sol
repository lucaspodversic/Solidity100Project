// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title PermitVaultVulnerable — firmas sin nonce ni domain → replay
/// @author Proyecto 57
contract PermitVaultVulnerable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    mapping(address => uint256) public balances;

    function deposit() external payable { balances[msg.sender] += msg.value; }

    /// @notice VULNERABLE: el hash no incluye nonce ni chainId ni address(this).
    ///         La misma firma se puede reusar (replay) y en otras chains/contratos.
    function withdrawWithSig(address from, uint256 amount, bytes calldata sig) external {
        bytes32 hash = keccak256(abi.encodePacked(from, amount)).toEthSignedMessageHash();
        address signer = ECDSA.recover(hash, sig);
        require(signer == from, "sig");
        require(balances[from] >= amount, "bal");
        balances[from] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay");
    }
}

/// @title PermitVaultSafe — EIP-712 con domain + nonce
contract PermitVaultSafe {
    using ECDSA for bytes32;

    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address from,uint256 amount,uint256 nonce)");
    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public nonces;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("PermitVaultSafe")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    function deposit() external payable { balances[msg.sender] += msg.value; }

    function withdrawWithSig(address from, uint256 amount, uint256 nonce, bytes calldata sig) external {
        require(nonce == nonces[from], "nonce");
        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, from, amount, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, sig);
        require(signer == from, "sig");
        nonces[from] = nonce + 1; // EFFECTS antes de pagar
        require(balances[from] >= amount, "bal");
        balances[from] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay");
    }
}
