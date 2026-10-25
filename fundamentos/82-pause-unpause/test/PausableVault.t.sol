// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PausableVault} from "../src/PausableVault.sol";

contract PausableVaultTest is Test {
    PausableVault v;
    address alice = makeAddr("alice");

    function setUp() public {
        v = new PausableVault();
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        v.deposit{value: 2 ether}();
    }

    function test_PausaBloqueaOperaciones() public {
        v.pause();
        vm.startPrank(alice);
        vm.expectRevert(PausableVault.EnforcedPause.selector);
        v.deposit{value: 1 ether}();
        vm.expectRevert(PausableVault.EnforcedPause.selector);
        v.withdraw(1 ether);
        vm.stopPrank();
    }

    function test_RetiroDeEmergencia() public {
        v.pause();
        vm.prank(alice);
        v.emergencyWithdraw();
        assertEq(alice.balance, 5 ether);
    }

    function test_EmergenciaSoloEnPausa() public {
        vm.prank(alice);
        vm.expectRevert(PausableVault.ExpectedPause.selector);
        v.emergencyWithdraw();
    }

    function test_Despausar() public {
        v.pause();
        v.unpause();
        vm.prank(alice);
        v.withdraw(1 ether);
        assertEq(v.balances(alice), 1 ether);
    }

    function test_SoloGuardian() public {
        vm.prank(alice);
        vm.expectRevert(PausableVault.NotGuardian.selector);
        v.pause();
    }

    function test_NoDoblePausa() public {
        v.pause();
        vm.expectRevert(PausableVault.EnforcedPause.selector);
        v.pause();
    }
}
