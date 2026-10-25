// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {TokenVesting} from "../src/TokenVesting.sol";

contract VestingTest is Test {
    MockERC20 tok; TokenVesting vest;
    address bene = makeAddr("bene");

    function setUp() public {
        tok = new MockERC20();
        vest = new TokenVesting(address(tok));
        tok.mint(address(this), 1000e18);
        tok.approve(address(vest), type(uint256).max);
    }

    function test_CliffYVestingLineal() public {
        uint64 start = uint64(block.timestamp);
        uint256 id = vest.createGrant(bene, 100e18, start, 30 days, 100 days, true);
        assertEq(vest.releasable(id), 0);
        vm.warp(start + 30 days);
        assertEq(vest.releasable(id), 30e18);
        vm.prank(bene); vest.release(id);
        assertEq(tok.balanceOf(bene), 30e18);
        vm.warp(start + 100 days);
        vm.prank(bene); vest.release(id);
        assertEq(tok.balanceOf(bene), 100e18);
    }

    function test_Revoke() public {
        uint64 start = uint64(block.timestamp);
        uint256 id = vest.createGrant(bene, 100e18, start, 0, 100 days, true);
        vm.warp(start + 40 days);
        uint256 owner0 = tok.balanceOf(address(this));
        vest.revoke(id);
        assertEq(tok.balanceOf(bene), 40e18);
        assertEq(tok.balanceOf(address(this)) - owner0, 60e18);
    }

    function test_SoloBeneRelease() public {
        uint256 id = vest.createGrant(bene, 10e18, uint64(block.timestamp), 0, 1 days, false);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(TokenVesting.NotBene.selector);
        vest.release(id);
    }
}
