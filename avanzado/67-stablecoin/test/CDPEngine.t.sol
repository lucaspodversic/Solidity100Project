// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CDPEngine, IPriceFeed} from "../src/CDPEngine.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {MockCollateral, MockOracle} from "../src/Mocks.sol";

contract CDPEngineTest is Test {
    CDPEngine eng;
    Stablecoin usd;
    MockCollateral weth;
    MockOracle ethFeed;
    MockOracle pegFeed;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob"); // liquidador
    address treasury = makeAddr("treasury");

    function setUp() public {
        vm.warp(1_700_000_000);
        weth = new MockCollateral();
        ethFeed = new MockOracle(2000e8);
        pegFeed = new MockOracle(1e8);
        eng = new CDPEngine(weth, IPriceFeed(address(ethFeed)), IPriceFeed(address(pegFeed)), treasury, 10_000_000e18);
        usd = eng.stable();
        weth.mint(alice, 100 ether);
        weth.mint(bob, 100 ether);
        vm.prank(alice);
        weth.approve(address(eng), type(uint256).max);
        vm.prank(bob);
        weth.approve(address(eng), type(uint256).max);
    }

    function _open(address u, uint256 coll, uint256 debt) internal {
        vm.startPrank(u);
        eng.deposit(coll);
        eng.mint(debt);
        vm.stopPrank();
    }

    function test_MintWithinMCR() public {
        _open(alice, 10 ether, 13_000e18); // 20k USD de colateral / 13k = 153%
        assertEq(usd.balanceOf(alice), 13_000e18);
        assertGe(eng.collateralRatioBps(alice), 15_000);
    }

    function test_RevertWhen_MintAboveMCR() public {
        vm.startPrank(alice);
        eng.deposit(10 ether);
        vm.expectRevert(CDPEngine.BelowMCR.selector);
        eng.mint(13_400e18); // 149%
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawBreaksMCR() public {
        _open(alice, 10 ether, 10_000e18);
        vm.prank(alice);
        vm.expectRevert(CDPEngine.BelowMCR.selector);
        eng.withdraw(3 ether); // 14k/10k = 140%
        vm.prank(alice);
        eng.withdraw(2 ether); // 16k/10k = 160%
        assertEq(weth.balanceOf(alice), 92 ether);
    }

    function test_RevertWhen_Dust() public {
        vm.startPrank(alice);
        eng.deposit(1 ether);
        vm.expectRevert(CDPEngine.DustVault.selector);
        eng.mint(50e18);
        vm.stopPrank();
    }

    function test_RevertWhen_Ceiling() public {
        eng.setDebtCeiling(1_000e18);
        vm.startPrank(alice);
        eng.deposit(10 ether);
        vm.expectRevert(CDPEngine.CeilingExceeded.selector);
        eng.mint(2_000e18);
        vm.stopPrank();
    }

    function test_InterestAccruesToTreasury() public {
        _open(alice, 10 ether, 10_000e18);
        vm.warp(block.timestamp + 365 days);
        ethFeed.set(2000e8);
        eng.drip();
        // 2% anual (compuesto discreto con un solo drip = exactamente 2%)
        assertApproxEqRel(eng.debtOf(alice), 10_200e18, 1e12);
        assertApproxEqAbs(usd.balanceOf(treasury), 200e18, 1e6);
    }

    function test_RepayAllClosesVault() public {
        _open(alice, 10 ether, 10_000e18);
        vm.warp(block.timestamp + 30 days);
        ethFeed.set(2000e8);
        eng.drip();
        uint256 debt = eng.debtOf(alice);
        // alice consigue el interés en el mercado (simulado con deal). La deuda se
        // redondea HACIA ARRIBA (a favor del protocolo), por eso puede faltar 1 wei
        // respecto de lo acuñado al treasury.
        deal(address(usd), alice, debt);
        vm.prank(alice);
        eng.repay(type(uint256).max);
        assertEq(eng.debtOf(alice), 0);
        assertEq(usd.balanceOf(alice), 0);
        vm.prank(alice);
        eng.withdraw(10 ether);
    }

    function test_DynamicRateBelowPeg() public {
        pegFeed.set(0.98e8); // 2% bajo el peg
        eng.updateRate();
        assertEq(eng.annualRateBps(), 200 + 2 * 200); // 6%
        pegFeed.set(0.5e8); // depeg extremo
        eng.updateRate();
        assertEq(eng.annualRateBps(), 5_000); // techo
    }

    function test_DynamicRateAbovePeg() public {
        pegFeed.set(1.005e8); // +0,5%
        eng.updateRate();
        assertEq(eng.annualRateBps(), 100);
        pegFeed.set(1.05e8);
        eng.updateRate();
        assertEq(eng.annualRateBps(), 0); // piso
    }

    function test_Liquidation() public {
        _open(alice, 10 ether, 13_000e18);
        _open(bob, 50 ether, 20_000e18);
        // ETH cae a 1600: 16k / 13k = 123% < 130%
        ethFeed.set(1600e8);
        uint256 repayAmt = 6_500e18; // 50%
        uint256 wethBefore = weth.balanceOf(bob);
        vm.prank(bob);
        eng.liquidate(alice, repayAmt);
        // seize = 6500/1600 * 1.1 = 4.46875 ETH
        assertEq(weth.balanceOf(bob) - wethBefore, 4.46875 ether);
        assertApproxEqAbs(eng.debtOf(alice), 6_500e18, 1);
        // tras la liquidación el vault mejora: 5.53125*1600 / 6500 = 136%
        assertGt(eng.collateralRatioBps(alice), 13_000);
    }

    function test_RevertWhen_LiquidateHealthy() public {
        _open(alice, 10 ether, 10_000e18);
        vm.prank(bob);
        vm.expectRevert(CDPEngine.NotLiquidatable.selector);
        eng.liquidate(alice, 1_000e18);
    }

    function test_RevertWhen_ExceedsCloseFactor() public {
        _open(alice, 10 ether, 13_000e18);
        _open(bob, 50 ether, 20_000e18);
        ethFeed.set(1600e8);
        vm.prank(bob);
        vm.expectRevert(CDPEngine.ExceedsCloseFactor.selector);
        eng.liquidate(alice, 7_000e18);
    }

    function test_BadDebtRecorded() public {
        _open(alice, 1 ether, 1_000e18);
        _open(bob, 50 ether, 20_000e18);
        ethFeed.set(500e8); // colapso: 500 / 1000 = 50%
        vm.prank(bob);
        // deuda 1000 - 500 = 500 >= DUST, close factor 50%
        eng.liquidate(alice, 500e18);
        // seize = 500/500*1.1 = 1.1 ETH > 1 ETH -> toma todo, resto a badDebt
        assertEq(eng.badDebt(), 500e18);
        assertEq(eng.debtOf(alice), 0);
        (uint256 c,) = eng.vaults(alice);
        assertEq(c, 0);
    }

    function test_RevertWhen_StaleOracle() public {
        vm.startPrank(alice);
        eng.deposit(10 ether);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(CDPEngine.StalePrice.selector);
        eng.mint(1_000e18);
        vm.stopPrank();
    }

    function test_RevertWhen_BadPrice() public {
        ethFeed.set(0);
        vm.startPrank(alice);
        eng.deposit(10 ether);
        vm.expectRevert(CDPEngine.BadPrice.selector);
        eng.mint(1_000e18);
        vm.stopPrank();
    }

    function test_RevertWhen_NotEngineMints() public {
        vm.expectRevert(Stablecoin.OnlyEngine.selector);
        usd.mint(alice, 1);
    }

    /// Invariante: oferta de USD100 ≈ deuda total (los intereses van al treasury).
    function testFuzz_SupplyMatchesDebt(uint256 debt, uint32 dt) public {
        debt = bound(debt, 100e18, 13_000e18);
        dt = uint32(bound(dt, 0, 3 * 365 days));
        _open(alice, 10 ether, debt);
        vm.warp(block.timestamp + dt);
        eng.drip();
        assertApproxEqAbs(usd.totalSupply(), eng.totalDebt(), 2);
        assertGe(eng.debtOf(alice), debt);
    }
}
