// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DutchAuction, DemoNFT} from "../src/DutchAuction.sol";

contract DutchAuctionTest is Test {
    DemoNFT nft;
    DutchAuction auc;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    function setUp() public {
        nft = new DemoNFT();
        nft.mint(seller, 1);
        vm.startPrank(seller);
        auc = new DutchAuction(nft, 1, 10 ether, 1 ether, 9 days);
        nft.approve(address(auc), 1);
        auc.start();
        vm.stopPrank();
        vm.deal(buyer, 20 ether);
    }

    function test_PrecioDecreceLineal() public {
        assertEq(auc.currentPrice(), 10 ether);
        vm.warp(block.timestamp + 3 days);
        assertEq(auc.currentPrice(), 7 ether);
        vm.warp(block.timestamp + 100 days);
        assertEq(auc.currentPrice(), 1 ether); // piso
    }

    function test_CompraConReembolso() public {
        vm.warp(block.timestamp + 6 days); // precio = 4 ETH
        vm.prank(buyer);
        auc.buy{value: 5 ether}();
        assertEq(nft.ownerOf(1), buyer);
        assertEq(seller.balance, 4 ether);
        assertEq(buyer.balance, 16 ether);
    }

    function test_RevertPagoInsuficiente() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DutchAuction.InsufficientPayment.selector, 1 ether, 10 ether));
        auc.buy{value: 1 ether}();
    }

    function test_RevertDobleCompra() public {
        vm.prank(buyer);
        auc.buy{value: 10 ether}();
        vm.prank(buyer);
        vm.expectRevert(DutchAuction.AuctionOver.selector);
        auc.buy{value: 10 ether}();
    }

    function test_ParamsInvalidos() public {
        vm.expectRevert(DutchAuction.InvalidParams.selector);
        new DutchAuction(nft, 1, 1 ether, 2 ether, 1 days);
    }

    function testFuzz_PrecioEntreLimites(uint32 dt) public {
        vm.warp(block.timestamp + dt);
        uint256 p = auc.currentPrice();
        assertLe(p, 10 ether);
        assertGe(p, 1 ether);
    }
}
