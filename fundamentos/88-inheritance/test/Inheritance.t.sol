// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ModularCounter, UnlimitedCounter} from "../src/Counter.sol";
import {Owned, Limited} from "../src/Base.sol";

contract InheritanceTest is Test {
    ModularCounter c;

    function setUp() public {
        c = new ModularCounter(2);
    }

    function test_LinealizacionSuper() public view {
        assertEq(c.describe(), "Counter>Limited>Logger>Owned");
    }

    function test_ModulosCompuestos() public {
        c.increment();
        c.increment();
        assertEq(c.count(), 2);
        assertEq(c.logCount(), 2);
        vm.expectRevert(Limited.LimitExceeded.selector);
        c.increment();
    }

    function test_OnlyOwnerHeredado() public {
        vm.prank(address(1));
        vm.expectRevert(Owned.NotOwner.selector);
        c.increment();
    }

    function test_OverrideHook() public {
        UnlimitedCounter u = new UnlimitedCounter();
        for (uint256 i; i < 10; i++) u.increment();
        assertEq(u.count(), 10);
        assertEq(u.describe(), "Limited>Owned");
    }

    function test_Polimorfismo() public view {
        // Un ModularCounter puede tratarse como Owned (upcast).
        Owned o = Owned(address(c));
        assertEq(o.owner(), address(this));
        assertEq(o.describe(), "Counter>Limited>Logger>Owned"); // despacho dinámico
    }
}
