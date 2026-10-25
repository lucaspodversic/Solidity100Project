// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {VaultVulnerable, VaultSafe} from "../src/Vault.sol";
import {ReentrancyAttacker} from "../src/Attacker.sol";

contract ReentrancyTest is Test {
    VaultVulnerable vul;
    VaultSafe safe;
    address victim = makeAddr("victim");

    function setUp() public {
        vul = new VaultVulnerable();
        safe = new VaultSafe();
        vm.deal(victim, 10 ether);
        vm.prank(victim); vul.deposit{value: 5 ether}();
        vm.prank(victim); safe.deposit{value: 5 ether}();
    }

    function test_AtaqueDrenaVulnerable() public {
        ReentrancyAttacker atk = new ReentrancyAttacker(address(vul));
        vm.deal(address(this), 1 ether);
        atk.attack{value: 1 ether}();
        assertEq(address(vul).balance, 0);
        assertTrue(address(atk).balance >= 5 ether);
    }

    function test_SafeResiste() public {
        // Atacante contra safe: el receive intenta reentrar y falla el mutex
        SafeAttacker atk = new SafeAttacker(address(safe));
        vm.deal(address(this), 1 ether);
        vm.expectRevert(); // withdraw reentrant revierte toda la tx
        atk.attack{value: 1 ether}();
        assertEq(address(safe).balance, 5 ether); // victim intacto
    }
}

contract SafeAttacker {
    VaultSafe public vault;
    constructor(address v) { vault = VaultSafe(v); }
    function attack() external payable {
        vault.deposit{value: msg.value}();
        vault.withdraw();
    }
    receive() external payable {
        if (address(vault).balance > 0) {
            vault.withdraw(); // dispara nonReentrant
        }
    }
}
