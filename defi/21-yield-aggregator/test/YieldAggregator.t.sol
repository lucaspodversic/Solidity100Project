// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {YieldAggregator} from "../src/YieldAggregator.sol";
import {MockYieldVault} from "../src/mocks/MockYieldVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests del agregador de rendimientos
/// @notice Fuentes (todas en USDC):
///   - A "Aave-like": TVL 1M, 10 % APR, riesgo 0     → score ≈ 10 %
///   - B "Degen":     TVL 1M, 20 % APR, riesgo 60 %  → score ≈ 8 %
///   - C "Chico":     TVL 50k, 15 % APR, riesgo 0    → no elegible (TVL < 100k)
contract YieldAggregatorTest is Test {
    MockERC20 usdc;
    YieldAggregator agg;
    MockYieldVault A;
    MockYieldVault B;
    MockYieldVault C;
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        agg = new YieldAggregator(IERC20(address(usdc)), 100_000e6);
        A = new MockYieldVault(IERC20(address(usdc)), "A");
        B = new MockYieldVault(IERC20(address(usdc)), "B");
        C = new MockYieldVault(IERC20(address(usdc)), "C");
        _seed(A, 1_000_000e6);
        _seed(B, 1_000_000e6);
        _seed(C, 50_000e6);
        agg.addSource(IERC4626(address(A)), "Aave-like", 0);
        agg.addSource(IERC4626(address(B)), "Degen", 6_000);
        agg.addSource(IERC4626(address(C)), "Chico", 0);
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(agg), type(uint256).max);
    }

    function _seed(MockYieldVault v, uint256 amt) internal {
        usdc.mint(address(this), amt);
        usdc.approve(address(v), amt);
        v.deposit(amt, address(this));
    }

    /// @dev Simula `aprBps` durante `days_` días en cada vault y hace poke.
    function _period(uint256 aprA, uint256 aprB, uint256 aprC, uint256 days_) internal {
        A.simulateYield((A.totalAssets() * aprA * days_) / (10_000 * 365));
        B.simulateYield((B.totalAssets() * aprB * days_) / (10_000 * 365));
        C.simulateYield((C.totalAssets() * aprC * days_) / (10_000 * 365));
        vm.warp(vm.getBlockTimestamp() + days_ * 1 days);
        agg.poke();
    }

    function test_NoEligibleBeforeMeasurement() public {
        vm.expectRevert(YieldAggregator.NoEligibleSource.selector);
        agg.best();
    }

    function test_RankingByRiskAdjustedScore() public {
        _period(1_000, 2_000, 1_500, 30);
        YieldAggregator.Row[] memory r = agg.ranking();
        assertEq(r[0].name, "Aave-like");
        assertEq(r[1].name, "Degen");
        assertEq(r[2].name, "Chico");
        assertApproxEqAbs(r[0].apyBps, 1_000, 2);
        assertApproxEqAbs(r[1].apyBps, 2_000, 2);
        assertApproxEqAbs(r[1].score, 800, 2, "20 % * (1 - 60 %)");
        assertApproxEqAbs(r[2].apyBps, 1_500, 2);
        assertTrue(r[0].eligible && r[1].eligible);
        assertFalse(r[2].eligible, "TVL insuficiente");
    }

    function test_MinWindowIgnoresFastPokes() public {
        _period(1_000, 2_000, 1_500, 30);
        uint256 before = agg.source(1).apyBps;
        B.simulateYield(50_000e6); // "rendimiento" enorme...
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        agg.poke(); // ...pero la ventana es muy corta: no se actualiza
        assertEq(agg.source(1).apyBps, before);
    }

    function test_DonationSpikeMakesSourceIneligible() public {
        _period(1_000, 2_000, 1_500, 30);
        // alguien dona 30 % del TVL a B para inflar su APY medido
        B.simulateYield(300_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        agg.poke();
        YieldAggregator.Row memory rb = agg.row(1);
        assertGt(rb.apyBps, agg.MAX_SANE_APY());
        assertFalse(rb.eligible, "APY sospechoso");
        assertEq(agg.best().name, "Aave-like");
    }

    function test_EmaSmoothing() public {
        _period(1_000, 2_000, 1_500, 30);
        _period(1_000, 0, 1_500, 30); // B deja de rendir
        assertApproxEqAbs(agg.source(1).apyBps, 1_400, 3, "0,7*2000 + 0,3*0");
        assertApproxEqAbs(agg.source(0).apyBps, 1_000, 3);
    }

    function test_LossGivesZeroSample() public {
        _period(1_000, 2_000, 1_500, 30);
        A.simulateLoss(10_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        agg.poke();
        assertApproxEqAbs(agg.source(0).apyBps, 700, 3);
    }

    function test_GovernanceChangesRanking() public {
        _period(1_000, 2_000, 1_500, 30);
        agg.setSource(1, 0, true); // B ahora sin riesgo → score 20 %
        assertEq(agg.best().name, "Degen");
        agg.setSource(1, 0, false); // desactivada
        assertEq(agg.best().name, "Aave-like");
        agg.setMinTvl(10_000e6); // C pasa a ser elegible y le gana a A
        assertEq(agg.best().name, "Chico");
    }

    function test_DepositBestRoutes() public {
        _period(1_000, 2_000, 1_500, 30);
        uint256 expected = A.previewDeposit(1_000e6);
        vm.prank(alice);
        (uint256 id, uint256 shares) = agg.depositBest(1_000e6, alice, expected);
        assertEq(id, 0);
        assertEq(shares, expected);
        assertEq(A.balanceOf(alice), shares, "shares directo al usuario");
        assertEq(usdc.balanceOf(address(agg)), 0);
        assertEq(usdc.allowance(address(agg), address(A)), 0, "sin allowance colgado");
    }

    function test_DepositBestSlippage() public {
        _period(1_000, 2_000, 1_500, 30);
        uint256 expected = A.previewDeposit(1_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YieldAggregator.Slippage.selector, expected, expected + 1));
        agg.depositBest(1_000e6, alice, expected + 1);
    }

    function test_AddSourceValidation() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockYieldVault d = new MockYieldVault(IERC20(address(dai)), "D");
        vm.expectRevert(YieldAggregator.WrongAsset.selector);
        agg.addSource(IERC4626(address(d)), "D", 0);
        vm.expectRevert(YieldAggregator.BadParam.selector);
        agg.addSource(IERC4626(address(A)), "A2", 10_001);
        vm.prank(alice);
        vm.expectRevert();
        agg.addSource(IERC4626(address(A)), "A3", 0);
    }

    /// @notice Fuzz: el APY medido refleja el APR simulado (±0,05 %).
    function testFuzz_MeasuredApy(uint256 apr, uint256 days_) public {
        apr = bound(apr, 0, 15_000);
        days_ = bound(days_, 1, 365);
        _period(apr, 0, 0, days_);
        assertApproxEqAbs(agg.source(0).apyBps, apr, 5);
    }
}
