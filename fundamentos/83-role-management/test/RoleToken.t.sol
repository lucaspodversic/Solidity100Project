// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RoleToken} from "../src/RoleToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract RoleTokenTest is Test {
    RoleToken t;
    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address pauser = makeAddr("pauser");
    address user = makeAddr("user");

    function setUp() public {
        t = new RoleToken(admin);
        vm.startPrank(admin);
        t.grantRole(t.MINTER_ROLE(), minter);
        t.grantRole(t.PAUSER_ROLE(), pauser);
        vm.stopPrank();
    }

    function test_MinterAcuna() public {
        vm.prank(minter);
        t.mint(user, 100);
        assertEq(t.balanceOf(user), 100);
    }

    function test_AdminNoAcunaSinRol() public {
        bytes32 role = t.MINTER_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        t.mint(user, 1);
    }

    function test_PauserPausa() public {
        vm.prank(minter);
        t.mint(user, 100);
        vm.prank(pauser);
        t.pause();
        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        t.transfer(minter, 1);
        vm.prank(pauser);
        t.unpause();
        vm.prank(user);
        t.transfer(minter, 1);
    }

    function test_RevocarMinter() public {
        bytes32 role = t.MINTER_ROLE();
        vm.prank(admin);
        t.revokeRole(role, minter);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter, role));
        t.mint(user, 1);
    }

    function test_RenunciarRol() public {
        bytes32 role = t.PAUSER_ROLE();
        vm.prank(pauser);
        t.renounceRole(role, pauser);
        assertFalse(t.hasRole(role, pauser));
    }

    function test_SoloAdminOtorga() public {
        bytes32 role = t.MINTER_ROLE();
        vm.prank(minter);
        vm.expectRevert();
        t.grantRole(role, user);
    }
}
