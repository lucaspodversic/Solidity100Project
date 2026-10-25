// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {GovToken} from "../src/GovToken.sol";
import {Governor} from "../src/Governor.sol";

contract Box { uint256 public x; function set(uint256 v) external { x=v; } }

contract GovTest is Test {
    GovToken tok; Governor gov; Box box;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        tok = new GovToken();
        // delay 10 bloques, period 50, threshold 10, quorum 50
        gov = new Governor(address(tok), 10, 50, 10e18, 50e18);
        box = new Box();
        tok.mint(alice, 80e18);
        tok.mint(bob, 40e18);
        vm.prank(alice); tok.delegate(alice);
        vm.prank(bob); tok.delegate(bob);
        vm.roll(block.number + 1); // checkpoint en el pasado
    }

    function test_Gobernanza() public {
        uint256 snapBlock = block.number;
        vm.prank(alice);
        uint256 id = gov.propose(address(box), 0, abi.encodeWithSelector(Box.set.selector, 7), "set7");
        assertEq(gov.snapshotOf(id), snapBlock);

        vm.prank(alice);
        vm.expectRevert(Governor.BadWindow.selector);
        gov.vote(id, true);

        vm.roll(snapBlock + 10); // startBlock
        vm.prank(alice); gov.vote(id, true);
        vm.prank(bob); gov.vote(id, false);

        vm.roll(snapBlock + 10 + 50);
        gov.execute(id);
        assertEq(box.x(), 7);
    }

    function test_SinThreshold() public {
        address pobre = makeAddr("pobre");
        vm.prank(pobre);
        vm.expectRevert(Governor.Threshold.selector);
        gov.propose(address(box), 0, "", "x");
    }
}
