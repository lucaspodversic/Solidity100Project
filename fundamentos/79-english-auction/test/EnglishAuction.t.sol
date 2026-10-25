// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EnglishAuction} from "../src/EnglishAuction.sol";

/// @dev Postor malicioso que rechaza ETH: no debe poder trabar la subasta.
contract RejectingBidder {
    function bid(EnglishAuction a) external payable {
        a.bid{value: msg.value}();
    }
    receive() external payable {
        revert("no acepto ETH");
    }
}

contract EnglishAuctionTest is Test {
    EnglishAuction auc;
    address seller = makeAddr("seller");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.prank(seller);
        auc = new EnglishAuction(1 ether, 0.1 ether, 1 days);
        vm.prank(seller);
        auc.start();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_PujasYPull() public {
        vm.prank(alice);
        auc.bid{value: 1 ether}();
        vm.prank(bob);
        auc.bid{value: 1.1 ether}();
        assertEq(auc.highestBidder(), bob);
        assertEq(auc.pendingReturns(alice), 1 ether);
        vm.prank(alice);
        auc.withdraw();
        assertEq(alice.balance, 10 ether);
    }

    function test_RevertPujaBaja() public {
        vm.prank(alice);
        auc.bid{value: 1 ether}();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EnglishAuction.BidTooLow.selector, 1.05 ether, 1.1 ether));
        auc.bid{value: 1.05 ether}();
    }

    function test_AntiSnipingExtiende() public {
        uint256 fin = auc.endTime();
        vm.warp(fin - 1 minutes);
        vm.prank(alice);
        auc.bid{value: 1 ether}();
        assertEq(auc.endTime(), block.timestamp + 10 minutes);
    }

    function test_SettlePagaVendedor() public {
        vm.prank(alice);
        auc.bid{value: 2 ether}();
        vm.warp(auc.endTime());
        auc.settle();
        assertEq(seller.balance, 2 ether);
        vm.expectRevert(EnglishAuction.AlreadySettled.selector);
        auc.settle();
    }

    function test_RevertSettleAntes() public {
        vm.expectRevert(EnglishAuction.AuctionNotEnded.selector);
        auc.settle();
    }

    function test_RevertPujaTrasCierre() public {
        vm.warp(auc.endTime());
        vm.prank(alice);
        vm.expectRevert(EnglishAuction.AuctionEnded.selector);
        auc.bid{value: 1 ether}();
    }

    /// @notice Un contrato que rechaza ETH no bloquea a los demás gracias a pull.
    function test_PostorMaliciosoNoBloquea() public {
        RejectingBidder evil = new RejectingBidder();
        vm.deal(address(evil), 5 ether);
        vm.prank(address(evil));
        evil.bid{value: 1 ether}(auc);
        vm.prank(bob);
        auc.bid{value: 1.2 ether}(); // no revierte aunque evil rechace ETH
        assertEq(auc.highestBidder(), bob);
    }
}
