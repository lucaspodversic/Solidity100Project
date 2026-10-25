// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {MockNFT} from "../src/MockNFT.sol";
import {NFTSwap} from "../src/NFTSwap.sol";

contract SwapTest is Test {
    MockNFT a; MockNFT b; NFTSwap swap;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        a = new MockNFT("A"); b = new MockNFT("B");
        swap = new NFTSwap();
        vm.deal(alice, 2 ether); vm.deal(bob, 2 ether);
        a.mint(alice); b.mint(bob);
        vm.prank(alice); a.approve(address(swap), 1);
        vm.prank(bob); b.approve(address(swap), 1);
    }

    function test_Swap1a1() public {
        NFTSwap.Item[] memory off = new NFTSwap.Item[](1);
        off[0] = NFTSwap.Item(address(a), 1);
        NFTSwap.Item[] memory want = new NFTSwap.Item[](1);
        want[0] = NFTSwap.Item(address(b), 1);
        vm.prank(alice);
        uint256 id = swap.create{value: 0.1 ether}(off, want, 0.05 ether);
        vm.prank(bob);
        swap.accept{value: 0.05 ether}(id);
        assertEq(a.ownerOf(1), bob);
        assertEq(b.ownerOf(1), alice);
    }

    function test_Cancel() public {
        NFTSwap.Item[] memory off = new NFTSwap.Item[](1);
        off[0] = NFTSwap.Item(address(a), 1);
        NFTSwap.Item[] memory want = new NFTSwap.Item[](0);
        vm.prank(alice);
        uint256 id = swap.create{value: 0.2 ether}(off, want, 0);
        vm.prank(alice); swap.cancel(id);
        assertEq(a.ownerOf(1), alice);
    }
}
