// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimeLock} from "../src/TimeLock.sol";

/// @dev Contrato objetivo cuyo setter solo debería tocar el timelock.
contract Target {
    uint256 public x;
    function setX(uint256 v) external { x = v; }
}

contract TimeLockTest is Test {
    TimeLock tl;
    Target target;
    address alice = makeAddr("alice");

    function setUp() public {
        tl = new TimeLock();
        target = new Target();
        vm.deal(alice, 10 ether);
    }

    function test_DepositoBloqueado() public {
        vm.prank(alice);
        tl.deposit{value: 1 ether}(1 weeks);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.StillLocked.selector, block.timestamp, block.timestamp + 1 weeks));
        tl.withdraw();
        vm.warp(block.timestamp + 1 weeks);
        vm.prank(alice);
        tl.withdraw();
        assertEq(alice.balance, 10 ether);
    }

    function test_NoAcortarBloqueo() public {
        vm.startPrank(alice);
        tl.deposit{value: 1 ether}(1 weeks);
        vm.expectRevert(TimeLock.CannotShortenLock.selector);
        tl.extendLock(block.timestamp + 1 days);
        tl.extendLock(block.timestamp + 2 weeks);
        vm.stopPrank();
        assertEq(tl.unlockTime(alice), block.timestamp + 2 weeks);
    }

    function test_QueueExecute() public {
        bytes memory data = abi.encodeCall(Target.setX, (42));
        uint256 eta = block.timestamp + 2 days;
        tl.queue(address(target), 0, data, eta);
        vm.expectRevert(abi.encodeWithSelector(TimeLock.TooEarly.selector, block.timestamp, eta));
        tl.execute(address(target), 0, data, eta);
        vm.warp(eta);
        tl.execute(address(target), 0, data, eta);
        assertEq(target.x(), 42);
    }

    function test_RevertDelayCorto() public {
        vm.expectRevert(TimeLock.DelayTooShort.selector);
        tl.queue(address(target), 0, "", block.timestamp + 1 days);
    }

    function test_Expira() public {
        bytes memory data = abi.encodeCall(Target.setX, (1));
        uint256 eta = block.timestamp + 3 days;
        tl.queue(address(target), 0, data, eta);
        vm.warp(eta + 14 days + 1);
        vm.expectRevert();
        tl.execute(address(target), 0, data, eta);
    }

    function test_Cancelar() public {
        uint256 eta = block.timestamp + 3 days;
        bytes32 id = tl.queue(address(target), 0, "", eta);
        tl.cancel(id);
        assertFalse(tl.queued(id));
    }

    function test_SoloOwnerEncola() public {
        vm.prank(alice);
        vm.expectRevert(TimeLock.NotOwner.selector);
        tl.queue(address(target), 0, "", block.timestamp + 3 days);
    }
}
