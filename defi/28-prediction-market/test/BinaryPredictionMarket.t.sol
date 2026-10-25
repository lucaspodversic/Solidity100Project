// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BinaryPredictionMarket as M} from "../src/BinaryPredictionMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract BinaryPredictionMarketTest is Test {
    MockERC20 usdc;
    M market;

    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address resolver = makeAddr("resolver");
    address arbitrator = makeAddr("arbitrator");
    address disputer = makeAddr("disputer");

    uint64 closeTime;
    uint256 constant BOND = 500e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        closeTime = uint64(vm.getBlockTimestamp() + 30 days);
        market = new M(usdc, "ETH > 5000 USD el 31/12?", closeTime, resolver, arbitrator, BOND, 1 days, 100);
        address[5] memory us = [lp, alice, bob, resolver, disputer];
        for (uint256 i; i < us.length; i++) {
            usdc.mint(us[i], 1_000_000e6);
            vm.prank(us[i]);
            usdc.approve(address(market), type(uint256).max);
        }
    }

    function _seed(uint256 prob) internal {
        vm.prank(lp);
        market.addLiquidity(10_000e6, prob);
    }

    function _resolve(M.Outcome o) internal {
        vm.warp(closeTime);
        vm.prank(resolver);
        market.propose(o);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        market.finalize();
    }

    // -------------------------------------------------------------- sets

    function test_SplitMerge() public {
        vm.startPrank(alice);
        market.split(100e6);
        assertEq(market.balanceOf(alice, 0), 100e6);
        assertEq(market.balanceOf(alice, 1), 100e6);
        market.merge(40e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 60e6);
    }

    // ---------------------------------------------------- precios = probabilidad

    function test_InitialProbabilityAndExcessTokens() public {
        _seed(0.7e18);
        assertApproxEqAbs(market.priceYes(), 0.7e18, 1e12);
        assertApproxEqAbs(market.priceYes() + market.priceNo(), 1e18, 0);
        // P(YES)=0,7 → reservas y=4285,71 n=10000; el LP se queda con los YES sobrantes
        assertApproxEqAbs(market.balanceOf(lp, 0), 10_000e6 - 4_285.714285e6, 1);
        assertEq(market.balanceOf(lp, 1), 0);
    }

    function test_BuyMovesProbability() public {
        _seed(0.5e18);
        (uint256 expOut, uint256 fee) = market.calcBuy(0, 1_000e6);
        assertEq(fee, 10e6);
        vm.prank(alice);
        uint256 out = market.buy(0, 1_000e6, expOut);
        assertEq(out, expOut);
        // x = 990; out = 10990 − ceil(1e8·1e12/10990e6) ≈ 1890,82 YES
        assertApproxEqAbs(out, 1_890.818926e6, 1);
        uint256 p = market.priceYes();
        assertGt(p, 0.5e18);
        emit log_named_decimal_uint("P(YES) tras comprar 1000 USDC", p, 18);
        // precio medio pagado (0,529) entre el precio antes (0,5) y el después
        uint256 avg = 1_000e6 * 1e18 / out;
        assertGt(avg, 0.5e18);
        assertLt(avg, p);
    }

    function test_MarginalPriceEqualsProbability() public {
        _seed(0.3e18);
        uint256 p = market.priceYes();
        (uint256 out,) = market.calcBuy(0, 1e6); // compra minúscula (con fee 1 %)
        uint256 cost = uint256(1e6) * 1e18 / out;
        assertApproxEqRel(cost, p * 10_000 / 9_900, 0.001e18);
    }

    function test_SellAndRoundTripLosesOnlyFees() public {
        _seed(0.5e18);
        vm.startPrank(alice);
        uint256 out = market.buy(0, 1_000e6, 0);
        // vende lo máximo posible ≈ recupera 1000 − fees
        uint256 back = 979e6;
        (uint256 tokensIn,) = market.calcSell(0, back);
        assertLe(tokensIn, out);
        market.sell(0, back, tokensIn);
        vm.stopPrank();
        assertApproxEqAbs(market.priceYes(), 0.5e18, 0.002e18);
        // 1000 → 979 + pocos YES sobrantes: el ida-y-vuelta cuesta ≈ 2 % (1 % por pata)
        assertLt(usdc.balanceOf(alice), 1_000_000e6 - 20e6);
    }

    function test_SlippageGuards() public {
        _seed(0.5e18);
        (uint256 o,) = market.calcBuy(1, 500e6);
        vm.prank(alice);
        vm.expectRevert(M.Slippage.selector);
        market.buy(1, 500e6, o + 1);
    }

    // --------------------------------------------------------- resolución

    function test_ResolveYesAndRedeem() public {
        _seed(0.5e18);
        vm.prank(alice);
        uint256 yes = market.buy(0, 1_000e6, 0);
        vm.prank(bob);
        uint256 no = market.buy(1, 1_000e6, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.WrongPhase.selector, M.Phase.Open));
        market.redeem();

        _resolve(M.Outcome.Yes);
        assertEq(uint8(market.phase()), uint8(M.Phase.Final));
        vm.prank(alice);
        assertEq(market.redeem(), yes);
        vm.prank(bob);
        assertEq(market.redeem(), 0);
        assertGt(no, 0);
        // el resolver recuperó su bond
        assertEq(usdc.balanceOf(resolver), 1_000_000e6);
    }

    function test_DisputeAndArbitration() public {
        _seed(0.5e18);
        vm.warp(closeTime);
        vm.prank(resolver);
        market.propose(M.Outcome.No);
        vm.prank(disputer);
        market.dispute();
        vm.expectRevert(abi.encodeWithSelector(M.WrongPhase.selector, M.Phase.Disputed));
        market.finalize();
        vm.expectRevert(M.OnlyArbitrator.selector);
        market.arbitrate(M.Outcome.Yes);
        vm.prank(arbitrator);
        market.arbitrate(M.Outcome.Yes);
        assertEq(uint8(market.finalOutcome()), uint8(M.Outcome.Yes));
        // el disputante tenía razón: se lleva los dos bonds
        assertEq(usdc.balanceOf(disputer), 1_000_000e6 + BOND);
        assertEq(usdc.balanceOf(resolver), 1_000_000e6 - BOND);
    }

    function test_DisputeWindowAndPhases() public {
        _seed(0.5e18);
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(M.WrongPhase.selector, M.Phase.Open));
        market.propose(M.Outcome.Yes);
        vm.warp(closeTime);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M.WrongPhase.selector, M.Phase.Closed));
        market.buy(0, 1e6, 0);
        vm.prank(alice);
        vm.expectRevert(M.OnlyResolver.selector);
        market.propose(M.Outcome.Yes);
        vm.prank(resolver);
        market.propose(M.Outcome.Yes);
        vm.expectRevert(abi.encodeWithSelector(M.WrongPhase.selector, M.Phase.Proposed));
        market.finalize(); // ventana abierta
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(disputer);
        vm.expectRevert(abi.encodeWithSelector(M.WrongPhase.selector, M.Phase.Proposed));
        market.dispute(); // ventana cerrada
    }

    function test_InvalidPaysHalf() public {
        vm.prank(alice);
        market.split(100e6);
        vm.prank(alice);
        market.safeTransferFrom(alice, bob, 1, 100e6, ""); // alice queda con 100 YES, bob con 100 NO
        _resolve(M.Outcome.Invalid);
        vm.prank(alice);
        assertEq(market.redeem(), 50e6);
        vm.prank(bob);
        assertEq(market.redeem(), 50e6);
    }

    function test_LpEarnsFeesAndRedeems() public {
        _seed(0.5e18);
        vm.prank(alice);
        market.buy(0, 2_000e6, 0);
        vm.prank(bob);
        market.buy(1, 2_000e6, 0);
        assertEq(market.pendingFees(lp), 40e6);
        _resolve(M.Outcome.No);
        uint256 shares = market.lpShares(lp);
        vm.startPrank(lp);
        market.removeLiquidity(shares);
        uint256 got = market.redeem();
        vm.stopPrank();
        emit log_named_uint("LP: USDC canjeados", got / 1e6);
        assertEq(usdc.balanceOf(lp), 1_000_000e6 - 10_000e6 + 40e6 + got);
    }

    /// @notice Solvencia: con trades aleatorios y cualquier resultado, todos cobran y el
    ///         contrato no queda debiendo (solo polvo).
    function testFuzz_Solvency(uint256 a, uint256 b, uint256 c, uint8 outcomeRaw) public {
        _seed(0.5e18);
        a = bound(a, 1e6, 50_000e6);
        b = bound(b, 1e6, 50_000e6);
        c = bound(c, 0, 1_000e6);
        vm.prank(alice);
        uint256 yes = market.buy(0, a, 0);
        vm.prank(bob);
        market.buy(1, b, 0);
        if (c > 0) {
            (uint256 need,) = market.calcSell(0, c);
            if (need <= yes) {
                vm.prank(alice);
                market.sell(0, c, need);
            }
        }
        M.Outcome o = M.Outcome(1 + (outcomeRaw % 3));
        _resolve(o);
        vm.prank(alice);
        market.redeem();
        vm.prank(bob);
        market.redeem();
        uint256 shares = market.lpShares(lp);
        vm.startPrank(lp);
        market.removeLiquidity(shares);
        market.redeem();
        vm.stopPrank();
        assertLe(usdc.balanceOf(address(market)), 5);
    }
}
