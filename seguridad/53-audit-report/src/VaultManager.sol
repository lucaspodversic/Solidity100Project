// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VaultManager — contrato DeFi INTENCIONALMENTE vulnerable (sujeto de auditoría)
/// @author Proyecto 53
/// @notice Hallazgos documentados en AUDIT.md. Este archivo es la versión ORIGINAL.
contract VaultManager {
    mapping(address => uint256) public balances;
    address public owner;
    uint256 public totalDeposits;
    bool public paused;

    constructor() { owner = msg.sender; }

    // H-01: falta access control en setOwner
    function setOwner(address newOwner) external { owner = newOwner; }

    // H-02: reentrancy en withdraw
    function deposit() external payable {
        balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
    }
    /// @dev VULNERABLE estilo DAO: lee el balance, envía TODO, y recién después pone 0.
    ///      Así el atacante puede reentrar y volver a leer el balance lleno (sin underflow 0.8).
    function withdraw(uint256 amount) external {
        require(!paused, "paused");
        uint256 bal = balances[msg.sender];
        require(bal >= amount && amount == bal, "bal"); // forzamos withdraw-all para el PoC clásico
        (bool ok,) = msg.sender.call{value: bal}("");
        require(ok, "pay");
        balances[msg.sender] = 0; // efecto tarde
        totalDeposits -= bal;
    }

    // M-01: paused sin onlyOwner
    function setPaused(bool p) external { paused = p; }

    // M-02: overflow conceptual en versiones viejas; acá underflow de totalDeposits si desync
    // L-01: sin evento en deposit/withdraw
}
