// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OrderBookDEX} from "../src/OrderBookDEX.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests del libro de órdenes
contract OrderBookDEXTest is Test {
    OrderBookDEX dex;
    MockERC20 weth; // BASE
    MockERC20 usdc; // QUOTE
    address alice = makeAddr("alice"); // maker
    address bob = makeAddr("bob"); // taker
    address carol = makeAddr("carol");
    address fees = makeAddr("fees");

    uint256 constant P2000 = 2000e18;
    uint256 constant P2010 = 2010e18;
    uint256 constant P1990 = 1990e18;

    function setUp() public {
        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 18);
        dex = new OrderBookDEX(IERC20(address(weth)), IERC20(address(usdc)), 10, fees); // 0,1%
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    /// @dev Da saldo y aprobaciones a un usuario.
    function _fund(address u) internal {
        weth.mint(u, 1000 ether);
        usdc.mint(u, 10_000_000 ether);
        vm.startPrank(u);
        weth.approve(address(dex), type(uint256).max);
        usdc.approve(address(dex), type(uint256).max);
        vm.stopPrank();
    }

    function test_RestingOrdersBuildBook() public {
        vm.startPrank(alice);
        dex.placeLimitOrder(false, P2010, 1 ether, 10, true);
        dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        dex.placeLimitOrder(true, P1990, 1 ether, 10, true);
        vm.stopPrank();
        assertEq(dex.bestAsk(), P2000);
        assertEq(dex.bestBid(), P1990);
        assertEq(dex.askLevels().length, 2);
        // El escrow quedó en el contrato
        assertEq(weth.balanceOf(address(dex)), 2 ether);
        assertEq(usdc.balanceOf(address(dex)), 1990 ether);
    }

    function test_TakerBuyFillsAtMakerPrice() public {
        vm.prank(alice);
        dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        // Bob está dispuesto a pagar hasta 2010 pero ejecuta a 2000 (mejora de precio).
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        (uint256 id, uint256 filled) = dex.placeLimitOrder(true, P2010, 1 ether, 10, true);
        assertEq(id, 0, "sin remanente");
        assertEq(filled, 1 ether);
        assertEq(before - usdc.balanceOf(bob), 2000 ether + 2 ether, "precio maker + 0,1% fee");
        assertEq(dex.claimable(bob, address(weth)), 1 ether);
        assertEq(dex.claimable(alice, address(usdc)), 2000 ether);
        assertEq(dex.claimable(fees, address(usdc)), 2 ether);
        assertEq(dex.bestAsk(), 0);
    }

    function test_PartialFillLeavesMakerRemainder() public {
        vm.prank(alice);
        uint256 id;
        (id,) = dex.placeLimitOrder(false, P2000, 3 ether, 10, true);
        vm.prank(bob);
        dex.placeLimitOrder(true, P2000, 1 ether, 10, false);
        (,,, uint256 remaining,,,) = dex.orders(id);
        assertEq(remaining, 2 ether);
        assertEq(dex.depthAt(false, P2000), 2 ether);
    }

    function test_PartialFillTakerRestsRemainder() public {
        vm.prank(alice);
        dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        vm.prank(bob);
        (uint256 id, uint256 filled) = dex.placeLimitOrder(true, P2000, 3 ether, 10, true);
        assertEq(filled, 1 ether);
        assertGt(id, 0);
        assertEq(dex.bestBid(), P2000);
        assertEq(dex.depthAt(true, P2000), 2 ether);
    }

    function test_PriceTimePriorityFIFO() public {
        vm.prank(alice);
        (uint256 idA,) = dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        vm.prank(carol);
        (uint256 idC,) = dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        vm.prank(bob);
        dex.placeLimitOrder(true, P2000, 1 ether, 10, false);
        (,,, uint256 remA,,,) = dex.orders(idA);
        (,,, uint256 remC,,,) = dex.orders(idC);
        assertEq(remA, 0, "alice llego primero");
        assertEq(remC, 1 ether);
    }

    function test_SweepsMultipleLevels() public {
        vm.startPrank(alice);
        dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        dex.placeLimitOrder(false, P2010, 1 ether, 10, true);
        vm.stopPrank();
        vm.prank(bob);
        (, uint256 filled) = dex.placeLimitOrder(true, P2010, 2 ether, 10, false);
        assertEq(filled, 2 ether);
        assertEq(dex.claimable(alice, address(usdc)), 4010 ether);
    }

    function test_TakerSellHitsBidAndUsesEscrow() public {
        vm.prank(alice);
        dex.placeLimitOrder(true, P2000, 2 ether, 10, true);
        vm.prank(bob);
        (, uint256 filled) = dex.placeLimitOrder(false, P1990, 2 ether, 10, false);
        assertEq(filled, 2 ether);
        assertEq(dex.claimable(alice, address(weth)), 2 ether);
        // Bob recibe 4000 - 0,1%
        assertEq(dex.claimable(bob, address(usdc)), 4000 ether - 4 ether);
    }

    function test_CancelRefundsEscrow() public {
        vm.prank(alice);
        (uint256 id,) = dex.placeLimitOrder(true, P2000, 1 ether, 10, true);
        vm.prank(alice);
        dex.cancel(id);
        assertEq(dex.claimable(alice, address(usdc)), 2000 ether);
        assertEq(dex.bestBid(), 0);
        vm.prank(alice);
        dex.withdraw(IERC20(address(usdc)));
        assertEq(usdc.balanceOf(alice), 10_000_000 ether);
    }

    function test_CannotCancelOthersOrder() public {
        vm.prank(alice);
        (uint256 id,) = dex.placeLimitOrder(true, P2000, 1 ether, 10, true);
        vm.prank(bob);
        vm.expectRevert(OrderBookDEX.NotOwner.selector);
        dex.cancel(id);
    }

    function test_CancelMiddleOfQueueKeepsLinks() public {
        vm.prank(alice);
        (uint256 a1,) = dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        vm.prank(carol);
        (uint256 c1,) = dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        vm.prank(alice);
        (uint256 a2,) = dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        vm.prank(carol);
        dex.cancel(c1);
        vm.prank(bob);
        dex.placeLimitOrder(true, P2000, 2 ether, 10, false);
        (,,, uint256 r1,,,) = dex.orders(a1);
        (,,, uint256 r2,,,) = dex.orders(a2);
        assertEq(r1 + r2, 0);
    }

    function test_MaxMatchesBoundsGas() public {
        for (uint256 i; i < 5; i++) {
            vm.prank(alice);
            dex.placeLimitOrder(false, P2000, 1 ether, 10, true);
        }
        vm.prank(bob);
        (, uint256 filled) = dex.placeLimitOrder(true, P2000, 5 ether, 2, false);
        assertEq(filled, 2 ether, "solo 2 matches");
    }

    function test_DustOrderRejected() public {
        vm.prank(alice);
        vm.expectRevert(OrderBookDEX.DustOrder.selector);
        dex.placeLimitOrder(true, 1, 1, 10, true);
    }

    function _withdrawAll(address u) internal {
        vm.startPrank(u);
        dex.withdraw(IERC20(address(usdc)));
        dex.withdraw(IERC20(address(weth)));
        vm.stopPrank();
    }

    /// @notice Fuzz de conservación: tras cruzar y retirar todo, el DEX queda sin fondos
    ///         (nada se crea ni se pierde salvo la comisión, que también se retira).
    function testFuzz_Conservation(uint256 amtMaker, uint256 amtTaker, uint256 price) public {
        amtMaker = bound(amtMaker, 1e12, 100 ether);
        amtTaker = bound(amtTaker, 1e12, 100 ether);
        price = bound(price, 1e15, 10_000e18);
        vm.prank(alice);
        (uint256 id,) = dex.placeLimitOrder(true, price, amtMaker, 10, true);
        vm.prank(bob);
        dex.placeLimitOrder(false, price, amtTaker, 10, false);
        (,,, uint256 rem,,,) = dex.orders(id);
        if (rem > 0) {
            vm.prank(alice);
            dex.cancel(id);
        }
        _withdrawAll(alice);
        _withdrawAll(bob);
        _withdrawAll(fees);
        assertEq(usdc.balanceOf(address(dex)), 0);
        assertEq(weth.balanceOf(address(dex)), 0);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(fees), 20_000_000 ether);
    }
}
