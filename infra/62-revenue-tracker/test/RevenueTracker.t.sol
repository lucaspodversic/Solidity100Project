// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RevenueTracker} from "../src/RevenueTracker.sol";
import {MockToken, MockDex, MockLending} from "../src/MockFeeSources.sol";

/// @title Tests del RevenueTracker
contract RevenueTrackerTest is Test {
    RevenueTracker t;
    MockToken usdc;
    MockDex dex;
    MockLending lend;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address stakers = makeAddr("stakers");
    address trader = makeAddr("trader");

    function setUp() public {
        vm.warp(100 days);
        t = new RevenueTracker(owner);
        usdc = new MockToken("USD Coin", "USDC");
        dex = new MockDex(t);
        lend = new MockLending(t);
        vm.startPrank(owner);
        t.setSource(address(dex), "DEX", true);
        t.setSource(address(lend), "Lending", true);
        t.setShares(treasury, 3); // 30%
        t.setShares(stakers, 7);  // 70%
        vm.stopPrank();
        usdc.mint(trader, 1e30);
        vm.prank(trader);
        usdc.approve(address(dex), type(uint256).max);
    }

    function _swap(uint256 amt) internal {
        vm.prank(trader);
        dex.swap(usdc, amt);
    }

    /// Registro y totales.
    function test_RecordAndTotals() public {
        _swap(10_000e18); // fee 30
        assertEq(t.totalRevenue(address(usdc)), 30e18);
        assertEq(t.revenueBySource(address(dex), address(usdc)), 30e18);
        assertEq(usdc.balanceOf(address(t)), 30e18);
    }

    /// Reparto proporcional a shares.
    function test_ClaimProportional() public {
        _swap(100_000e18); // fee 300
        assertEq(t.pending(address(usdc), treasury), 90e18);
        assertEq(t.pending(address(usdc), stakers), 210e18);
        vm.prank(treasury);
        t.claim(address(usdc));
        assertEq(usdc.balanceOf(treasury), 90e18);
        assertEq(t.pending(address(usdc), treasury), 0);
    }

    /// ETH también se registra y reparte.
    function test_ETHRevenue() public {
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        lend.repay{value: 10 ether}(); // 1 ether de ingreso
        assertEq(t.totalRevenue(address(0)), 1 ether);
        vm.prank(stakers);
        t.claim(address(0));
        assertEq(stakers.balance, 0.7 ether);
    }

    /// Serie diaria y ventana de días.
    function test_DailySeries() public {
        _swap(10_000e18); // día 100: 30
        vm.warp(block.timestamp + 1 days);
        _swap(20_000e18); // día 101: 60
        vm.warp(block.timestamp + 1 days);
        _swap(30_000e18); // día 102: 90
        uint256[] memory s = t.revenueSeries(address(usdc), 3);
        assertEq(s[0], 90e18);
        assertEq(s[1], 60e18);
        assertEq(s[2], 30e18);
        assertEq(t.revenueLastDays(address(usdc), 2), 150e18);
    }

    /// Desglose por fuente.
    function test_Breakdown() public {
        _swap(10_000e18);
        (address[] memory srcs, uint256[] memory amts) = t.breakdown(address(usdc));
        assertEq(srcs.length, 2);
        assertEq(amts[0], 30e18);
        assertEq(amts[1], 0);
    }

    /// Fuentes no registradas o inactivas no pueden reportar.
    function test_RevertWhen_NotSource() public {
        vm.expectRevert(RevenueTracker.NotSource.selector);
        t.recordFeeETH{value: 1}();
        vm.prank(owner);
        t.setSource(address(dex), "DEX", false);
        vm.prank(trader);
        vm.expectRevert(RevenueTracker.NotSource.selector);
        dex.swap(usdc, 1000e18);
    }

    /// Cambiar shares no altera lo ya ganado.
    function test_ShareChangeNotRetroactive() public {
        _swap(100_000e18); // 300: 90 / 210
        vm.prank(owner);
        t.setShares(treasury, 7); // ahora 7/14 cada uno
        _swap(100_000e18); // 300: 150 / 150
        // tolerancia de 1 wei por redondeo del acumulador
        assertApproxEqAbs(t.pending(address(usdc), treasury), 90e18 + 150e18, 1);
        assertApproxEqAbs(t.pending(address(usdc), stakers), 210e18 + 150e18, 1);
    }

    /// Sólo el owner administra.
    function test_RevertWhen_NonOwnerAdmin() public {
        vm.prank(trader);
        vm.expectRevert();
        t.setShares(trader, 100);
    }

    /// Fuzz: la suma de pendientes nunca supera el balance del contrato.
    function testFuzz_SolvencyInvariant(uint96 a, uint96 b, uint8 newShares) public {
        a = uint96(bound(a, 1e18, 1e24));
        b = uint96(bound(b, 1e18, 1e24));
        _swap(a);
        vm.prank(owner);
        t.setShares(treasury, bound(newShares, 1, 50));
        _swap(b);
        uint256 sum = t.pending(address(usdc), treasury) + t.pending(address(usdc), stakers);
        assertLe(sum, usdc.balanceOf(address(t)));
        // el polvo de redondeo es despreciable (< 10 wei)
        assertApproxEqAbs(sum, usdc.balanceOf(address(t)), 10);
    }
}
