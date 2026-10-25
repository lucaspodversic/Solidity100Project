// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VaultVulnerable — reentrancy clásica (DAO hack style)
/// @notice VULNERABLE: actualiza el balance DESPUÉS del call externo.
contract VaultVulnerable {
    mapping(address => uint256) public balances;
    function deposit() external payable { balances[msg.sender] += msg.value; }
    function withdraw() external {
        uint256 bal = balances[msg.sender];
        require(bal > 0, "0");
        // INTERACTION antes de EFFECT → reentrancy
        (bool ok,) = msg.sender.call{value: bal}("");
        require(ok, "fail");
        balances[msg.sender] = 0;
    }
}

/// @title VaultSafe — Checks-Effects-Interactions + mutex
contract VaultSafe {
    mapping(address => uint256) public balances;
    bool private locked;
    modifier nonReentrant() {
        require(!locked, "reentrant");
        locked = true;
        _;
        locked = false;
    }
    function deposit() external payable { balances[msg.sender] += msg.value; }
    function withdraw() external nonReentrant {
        uint256 bal = balances[msg.sender];
        require(bal > 0, "0");
        balances[msg.sender] = 0; // EFFECT primero
        (bool ok,) = msg.sender.call{value: bal}("");
        require(ok, "fail");
    }
}
