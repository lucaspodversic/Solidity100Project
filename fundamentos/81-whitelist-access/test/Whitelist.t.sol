// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Whitelist} from "../src/Whitelist.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract WhitelistTest is Test {
    Whitelist wl;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        wl = new Whitelist();
    }

    function test_AltaYClaim() public {
        wl.add(alice);
        assertTrue(wl.isWhitelisted(alice));
        vm.prank(alice);
        wl.claim();
        assertEq(wl.totalClaims(), 1);
    }

    function test_RevertNoListado() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Whitelist.NotWhitelisted.selector, bob));
        wl.claim();
    }

    function test_RevertDobleClaim() public {
        wl.add(alice);
        vm.startPrank(alice);
        wl.claim();
        vm.expectRevert(abi.encodeWithSelector(Whitelist.AlreadyClaimed.selector, alice));
        wl.claim();
        vm.stopPrank();
    }

    function test_BatchYContador() public {
        address[] memory l = new address[](3);
        l[0] = alice; l[1] = bob; l[2] = alice; // duplicado no cuenta doble
        wl.addBatch(l);
        assertEq(wl.whitelistCount(), 2);
        wl.remove(bob);
        assertEq(wl.whitelistCount(), 1);
        assertFalse(wl.isWhitelisted(bob));
    }

    function test_SoloOwnerAgrega() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        wl.add(alice);
    }

    function test_RevertDireccionCero() public {
        vm.expectRevert(Whitelist.ZeroAddress.selector);
        wl.add(address(0));
    }
}
