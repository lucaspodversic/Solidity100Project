// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockNFT} from "../src/MockNFT.sol";
import {NFTLiquidityPool} from "../src/NFTLiquidityPool.sol";

contract LiquidityTest is Test {
    MockERC20 tok;
    MockNFT nft;
    NFTLiquidityPool pool;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        tok = new MockERC20();
        nft = new MockNFT();
        pool = new NFTLiquidityPool(address(nft), address(tok), 100e18, 10e18, 100); // fee 1%
        tok.mint(lp, 10000e18);
        tok.mint(trader, 10000e18);
        uint256[] memory ids = new uint256[](3);
        for (uint i; i < 3; ++i) ids[i] = nft.mint(lp);
        vm.startPrank(lp);
        nft.setApprovalForAll(address(pool), true);
        tok.approve(address(pool), type(uint256).max);
        pool.deposit(ids, 1000e18);
        vm.stopPrank();
        vm.prank(trader); tok.approve(address(pool), type(uint256).max);
    }

    function test_BuySell() public {
        uint256 price = pool.buyPrice();
        assertTrue(price > 0 && price < type(uint256).max);
        vm.prank(trader);
        uint256 id = pool.buy();
        assertEq(nft.ownerOf(id), trader);

        vm.startPrank(trader);
        nft.approve(address(pool), id);
        uint256 sell = pool.sellPrice();
        uint256 bal0 = tok.balanceOf(trader);
        pool.sell(id);
        assertEq(tok.balanceOf(trader) - bal0, sell);
        vm.stopPrank();
    }

    function test_WithdrawLP() public {
        uint256 s = pool.shares(lp);
        uint256 bal0 = tok.balanceOf(lp);
        vm.prank(lp);
        pool.withdraw(s / 2);
        assertTrue(tok.balanceOf(lp) > bal0);
    }

    function test_EmptyBuyRevierte() public {
        // compramos los 3
        vm.startPrank(trader);
        pool.buy(); pool.buy(); pool.buy();
        vm.expectRevert(NFTLiquidityPool.Empty.selector);
        pool.buy();
        vm.stopPrank();
    }
}
