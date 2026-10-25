// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VaultManagerFixed — parches de la auditoría
contract VaultManagerFixed {
    mapping(address => uint256) public balances;
    address public owner;
    uint256 public totalDeposits;
    bool public paused;
    bool private locked;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event OwnerUpdated(address indexed owner);
    event Paused(bool p);

    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }
    modifier nonReentrant() { require(!locked, "lock"); locked = true; _; locked = false; }

    constructor() { owner = msg.sender; }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "0");
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    function deposit() external payable {
        require(!paused, "paused");
        balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(!paused, "paused");
        require(balances[msg.sender] >= amount, "bal");
        balances[msg.sender] -= amount; // CEI
        totalDeposits -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay");
        emit Withdraw(msg.sender, amount);
    }
}
