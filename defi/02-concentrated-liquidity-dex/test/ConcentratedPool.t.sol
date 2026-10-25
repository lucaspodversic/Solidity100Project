// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConcentratedPool} from "../src/ConcentratedPool.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev Envoltorio para testear la librería (las funciones internas se exponen como externas).
contract TickMathHarness {
    function sqrtAt(int24 t) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(t);
    }

    function tickAt(uint160 s) external pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(s);
    }
}

/// @title Tests del DEX de liquidez concentrada
contract ConcentratedPoolTest is Test {
    ConcentratedPool pool;
    MockERC20 t0;
    MockERC20 t1;
    TickMathHarness tm;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        tm = new TickMathHarness();
        MockERC20 x = new MockERC20("X", "X", 18);
        MockERC20 y = new MockERC20("Y", "Y", 18);
        (t0, t1) = address(x) < address(y) ? (x, y) : (y, x);
        pool = new ConcentratedPool(IERC20(address(t0)), IERC20(address(t1)), 3000, 60);
        pool.initialize(uint160(TickMath.Q96)); // precio 1:1, tick 0
        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < 3; i++) {
            t0.mint(us[i], 1e30);
            t1.mint(us[i], 1e30);
            vm.startPrank(us[i]);
            t0.approve(address(pool), type(uint256).max);
            t1.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------- TickMath ----------------

    function test_TickZeroIsQ96() public view {
        assertEq(tm.sqrtAt(0), 2 ** 96);
    }

    function test_TickMathKnownValue() public view {
        // 1.0001^(10000/2) ≈ 1.648680 => tolerancia relativa 1e-9
        uint256 expected = 130621891405341611593710811005; // floor(sqrt(1.0001^10000)*2^96)
        assertApproxEqRel(tm.sqrtAt(10000), expected, 1e9);
    }

    function testFuzz_TickRoundTrip(int24 t) public view {
        t = int24(bound(t, -400_000, 400_000));
        assertEq(tm.tickAt(tm.sqrtAt(t)), t);
    }

    function testFuzz_TickMonotonic(int24 t) public view {
        t = int24(bound(t, -399_999, 399_999));
        assertLt(tm.sqrtAt(t), tm.sqrtAt(t + 1));
    }

    // ---------------- Liquidez ----------------

    function test_MintInRangeNeedsBothTokens() public {
        vm.prank(alice);
        (uint256 a0, uint256 a1) = pool.mint(-600, 600, 1e21);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(pool.liquidity(), 1e21);
    }

    function test_MintAboveRangeOnlyToken0() public {
        vm.prank(alice);
        (uint256 a0, uint256 a1) = pool.mint(600, 1200, 1e21);
        assertGt(a0, 0);
        assertEq(a1, 0);
        assertEq(pool.liquidity(), 0, "fuera de rango no es liquidez activa");
    }

    function test_MintBelowRangeOnlyToken1() public {
        vm.prank(alice);
        (uint256 a0, uint256 a1) = pool.mint(-1200, -600, 1e21);
        assertEq(a0, 0);
        assertGt(a1, 0);
    }

    function test_InvalidTicksRevert() public {
        vm.startPrank(alice);
        vm.expectRevert(ConcentratedPool.InvalidTicks.selector);
        pool.mint(600, 600, 1e18);
        vm.expectRevert(ConcentratedPool.InvalidTicks.selector);
        pool.mint(-61, 600, 1e18); // no múltiplo de tickSpacing
        vm.stopPrank();
    }

    function test_BurnReturnsPrincipalMinusRounding() public {
        vm.startPrank(alice);
        (uint256 a0, uint256 a1) = pool.mint(-600, 600, 1e21);
        (uint256 b0, uint256 b1) = pool.burn(-600, 600, 1e21);
        vm.stopPrank();
        // El redondeo favorece al pool: se devuelve como mucho lo aportado.
        assertLe(b0, a0);
        assertLe(b1, a1);
        assertApproxEqAbs(b0, a0, 2);
        assertApproxEqAbs(b1, a1, 2);
        assertEq(pool.getInitializedTicks().length, 0, "ticks limpiados");
    }

    // ---------------- Swaps ----------------

    function test_SwapZeroForOneLowersPrice() public {
        vm.prank(alice);
        pool.mint(-6000, 6000, 1e22);
        uint160 before = pool.sqrtPriceX96();
        uint256 b1 = t1.balanceOf(bob);
        vm.prank(bob);
        uint256 out = pool.swap(true, 1e19, 0, 0, bob);
        assertLt(pool.sqrtPriceX96(), before);
        assertEq(t1.balanceOf(bob) - b1, out);
        // Cerca de 1:1 con 0,3% de comisión: out < 10 * 0.997
        assertLt(out, 9.97e18);
        assertGt(out, 9.9e18);
        assertLt(pool.tick(), 0);
    }

    function test_SwapOneForZeroRaisesPrice() public {
        vm.prank(alice);
        pool.mint(-6000, 6000, 1e22);
        vm.prank(bob);
        pool.swap(false, 1e19, 0, 0, bob);
        assertGt(pool.tick(), -1);
        assertGt(pool.sqrtPriceX96(), 2 ** 96);
    }

    function test_SlippageReverts() public {
        vm.prank(alice);
        pool.mint(-6000, 6000, 1e22);
        vm.prank(bob);
        vm.expectRevert(ConcentratedPool.InsufficientOutput.selector);
        pool.swap(true, 1e19, 1e19, 0, bob);
    }

    function test_ConcentratedIsMoreCapitalEfficient() public {
        // Misma liquidez L: el rango estrecho necesita mucho menos capital…
        vm.prank(alice);
        (uint256 n0, uint256 n1) = pool.mint(-600, 600, 1e22);
        vm.prank(alice);
        pool.burn(-600, 600, 1e22);
        vm.prank(alice);
        (uint256 w0, uint256 w1) = pool.mint(-60000, 60000, 1e22);
        assertLt(n0 + n1, (w0 + w1) / 5);
    }

    function test_CrossTickChangesLiquidity() public {
        vm.prank(alice);
        pool.mint(-120, 120, 1e21); // rango estrecho
        vm.prank(carol);
        pool.mint(-6000, 6000, 1e21); // rango amplio
        assertEq(pool.liquidity(), 2e21);
        // Swap grande: el precio sale del rango estrecho
        vm.prank(bob);
        pool.swap(true, 5e19, 0, 0, bob);
        assertLt(pool.tick(), -120);
        assertEq(pool.liquidity(), 1e21, "solo queda la liquidez amplia");
        // Y volver cruza de nuevo
        vm.prank(bob);
        pool.swap(false, 1e20, 0, 0, bob);
        assertGt(pool.tick(), 120);
        assertEq(pool.liquidity(), 1e21);
    }

    function test_FeesOnlyForInRangePositions() public {
        vm.prank(alice);
        pool.mint(-600, 600, 1e22); // en rango
        vm.prank(carol);
        pool.mint(1200, 1800, 1e22); // fuera de rango
        // Swaps de ida y vuelta pequeños dentro del rango de alice
        for (uint256 i; i < 4; i++) {
            vm.startPrank(bob);
            pool.swap(true, 1e19, 0, 0, bob);
            pool.swap(false, 1e19, 0, 0, bob);
            vm.stopPrank();
        }
        vm.prank(alice);
        pool.burn(-600, 600, 0); // "poke" para materializar comisiones
        vm.prank(carol);
        pool.burn(1200, 1800, 0);
        (,,, uint128 aOwed0, uint128 aOwed1) = pool.positions(pool.positionKey(alice, -600, 600));
        (,,, uint128 cOwed0, uint128 cOwed1) = pool.positions(pool.positionKey(carol, 1200, 1800));
        assertGt(aOwed0, 0);
        assertGt(aOwed1, 0);
        assertEq(cOwed0 + cOwed1, 0, "fuera de rango no cobra");
        // ~0,3% de 4*1e19 = 1.2e17 por token
        assertApproxEqRel(aOwed0, 1.2e17, 0.01e18);
    }

    function test_PriceLimitStopsSwapAndChargesPartial() public {
        vm.prank(alice);
        pool.mint(-6000, 6000, 1e21);
        uint160 limit = tm.sqrtAt(-60);
        uint256 before = t0.balanceOf(bob);
        vm.prank(bob);
        pool.swap(true, 1e24, 0, limit, bob);
        assertEq(pool.sqrtPriceX96(), limit);
        assertLt(before - t0.balanceOf(bob), 1e24, "cobra solo lo usado");
    }

    /// @notice Fuzz de solvencia: tras swaps arbitrarios, todos los LP pueden salir y cobrar.
    function testFuzz_PoolStaysSolvent(uint256 s1, uint256 s2, bool dir) public {
        s1 = bound(s1, 1e6, 1e21);
        s2 = bound(s2, 1e6, 1e21);
        vm.prank(alice);
        pool.mint(-1200, 1200, 1e22);
        vm.prank(carol);
        pool.mint(-60000, 60000, 1e21);
        vm.startPrank(bob);
        pool.swap(dir, s1, 0, 0, bob);
        pool.swap(!dir, s2, 0, 0, bob);
        vm.stopPrank();
        vm.startPrank(alice);
        pool.burn(-1200, 1200, 1e22);
        pool.collect(-1200, 1200, type(uint128).max, type(uint128).max);
        vm.stopPrank();
        vm.startPrank(carol);
        pool.burn(-60000, 60000, 1e21);
        pool.collect(-60000, 60000, type(uint128).max, type(uint128).max);
        vm.stopPrank();
        assertEq(pool.liquidity(), 0);
    }
}
