// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Timelock} from "../src/Timelock.sol";
contract Box { uint256 public x; function set(uint256 v) external { x=v; } }
contract TimelockTest is Test {
    Timelock tl; Box box;
    address proposer = makeAddr("prop");
    address admin = makeAddr("admin");
    function setUp() public {
        tl = new Timelock(2 days, proposer, admin);
        box = new Box();
    }
    function test_QueueExecute() public {
        bytes memory data = abi.encodeWithSelector(Box.set.selector, 5);
        vm.prank(proposer);
        bytes32 id = tl.queue(address(box), 0, data, 1);
        vm.expectRevert(Timelock.Early.selector);
        tl.execute(address(box), 0, data, 1);
        vm.warp(block.timestamp + 2 days);
        tl.execute(address(box), 0, data, 1);
        assertEq(box.x(), 5);
        assertTrue(tl.done(id));
    }
    function test_Cancel() public {
        bytes memory data = abi.encodeWithSelector(Box.set.selector, 1);
        vm.prank(proposer); tl.queue(address(box), 0, data, 2);
        vm.prank(admin); tl.cancel(address(box), 0, data, 2);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(Timelock.NotQueued.selector);
        tl.execute(address(box), 0, data, 2);
    }
}
