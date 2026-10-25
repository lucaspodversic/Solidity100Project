// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FundingArbBot} from "../src/FundingArbBot.sol";
import {PerpMarket} from "../src/perp/PerpMarket.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Escenario: venue A está "cargado de longs" (funding +1 %/día) y venue B de shorts
///         (funding −1 %/día). El bot hace short A / long B y cobra en ambos.
contract FundingArbBotTest is Test {
    MockERC20 usdc;
    PriceOracle oracle;
    PerpMarket a;
    PerpMarket b;
    FundingArbBot bot;
    address constant ETH = address(0xE7);
    uint256 constant P0 = 2000e18;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address whaleA = makeAddr("whaleA");
    address whaleB = makeAddr("whaleB");
    address keeper = makeAddr("keeper");
    address lp = makeAddr("lp");

    uint256 constant CAPITAL = 200_000e6;
    uint256 constant SIZE = 50e18; // 50 ETH = 100k USD por leg
    uint256 constant MARGIN = 50_000e6; // 2x por leg

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new PriceOracle();
        oracle.setMaxAge(3650 days);
        oracle.setPrice(ETH, P0);
        a = new PerpMarket(usdc, oracle, ETH, 0.01e18, 100e18);
        b = new PerpMarket(usdc, oracle, ETH, 0.01e18, 100e18);

        _fundLp(a);
        _fundLp(b);
        _trader(whaleA, a, 100_000e6, 200e18); // skew A = +200 → +1 %/día (tope)
        _trader(whaleB, b, 300_000e6, -100e18); // skew B = −100 → −1 %/día

        bot = new FundingArbBot(usdc, a, b, owner, operator);
        usdc.mint(owner, CAPITAL);
        vm.prank(owner);
        usdc.transfer(address(bot), CAPITAL);
    }

    function _fundLp(PerpMarket v) internal {
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(v), type(uint256).max);
        v.lpDeposit(1_000_000e6);
        vm.stopPrank();
    }

    function _trader(address who, PerpMarket v, uint256 m, int256 size) internal {
        usdc.mint(who, m);
        vm.startPrank(who);
        usdc.approve(address(v), type(uint256).max);
        v.depositMargin(m);
        v.trade(size, size > 0 ? type(uint256).max : 0);
        vm.stopPrank();
    }

    function _open() internal {
        vm.prank(operator);
        bot.open(SIZE, MARGIN, P0, 50);
    }

    // ------------------------------------------------------------------ decisión

    function test_SpreadAndDirection() public {
        assertApproxEqAbs(bot.spreadPerDay(), 0.02e18, 1e9); // 1 % − (−1 %)
        assertTrue(bot.shouldOpen(SIZE));
        int256 preview = bot.previewEdge(SIZE);
        _open();
        assertTrue(bot.isOpen());
        assertTrue(bot.shortOnA());
        assertEq(a.positionOf(address(bot)).size, -int256(SIZE));
        assertEq(b.positionOf(address(bot)).size, int256(SIZE));
        // nuestros trades comprimen el spread: A sigue en tope (skew 150), B baja a −0,5 %
        assertApproxEqAbs(bot.edgePerDay(), 0.015e18, 1e9);
        assertEq(bot.edgePerDay(), preview); // el preview predice exactamente el edge real
        assertFalse(bot.shouldClose());
    }

    function test_OpenRevertsBelowEntry() public {
        vm.prank(owner);
        bot.setParams(0.03e18, 0.001e18, 100e18, 3_333, 1_500);
        vm.prank(operator);
        vm.expectPartialRevert(FundingArbBot.SpreadTooLow.selector);
        bot.open(SIZE, MARGIN, P0, 50);
    }

    /// @notice Un tamaño enorme da vuelta el skew de A: el arbitraje se "come" a sí mismo.
    function test_OpenRevertsIfOwnTradeKillsSpread() public {
        vm.prank(owner);
        bot.setParams(0.002e18, 0.0005e18, 1_000e18, 3_333, 1_500);
        usdc.mint(address(bot), 1_000_000e6);
        assertFalse(bot.shouldOpen(300e18)); // el preview ya lo anticipa
        vm.prank(operator);
        vm.expectPartialRevert(FundingArbBot.SpreadTooLowAfter.selector);
        bot.open(300e18, 200_000e6, P0, 50); // skew A → −100 (−1 %), skew B → +200 (+1 %)
    }

    function test_LimitsAndRoles() public {
        vm.startPrank(operator);
        vm.expectRevert(FundingArbBot.SizeTooLarge.selector);
        bot.open(101e18, 100_000e6, P0, 50);
        vm.expectRevert(FundingArbBot.MarginTooLow.selector);
        bot.open(SIZE, 20_000e6, P0, 50); // 5x > 3x permitido
        vm.expectPartialRevert(FundingArbBot.PriceDeviation.selector);
        bot.open(SIZE, MARGIN, 2100e18, 50); // el oráculo se movió 5 %
        // el operador NO puede sacar fondos
        vm.expectRevert();
        bot.withdraw(operator, 1);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(FundingArbBot.NotAuthorized.selector);
        bot.open(SIZE, MARGIN, P0, 50);
    }

    // ------------------------------------------------------------------ economía

    function test_PriceNeutral() public {
        _open();
        int256 eq0 = bot.totalEquity();
        assertApproxEqAbs(eq0, int256(CAPITAL - 100e6), 2); // solo pagó 2 fees de 50
        oracle.setPrice(ETH, 2400e18);
        assertApproxEqAbs(bot.totalEquity(), eq0, 2);
        oracle.setPrice(ETH, 1500e18);
        assertApproxEqAbs(bot.totalEquity(), eq0, 2);
    }

    function test_EarnsFundingThenCloses() public {
        _open();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // short A cobra 1 % de 100k (1000) + long B cobra 0,5 % de 100k (500)
        assertApproxEqRel(bot.totalEquity(), int256(CAPITAL - 100e6 + 1_500e6), 0.001e18);
        vm.prank(operator);
        bot.close();
        uint256 fin = usdc.balanceOf(address(bot));
        emit log_named_decimal_uint("Ganancia neta 1 dia (USDC)", fin - CAPITAL, 6);
        assertApproxEqRel(fin, CAPITAL + 1_300e6, 0.001e18); // − 4 fees de 50
        assertFalse(bot.isOpen());
        assertEq(a.margin(address(bot)), 0);
        assertEq(b.margin(address(bot)), 0);
    }

    function test_ConvergenceLetsAnyoneClose() public {
        _open();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(keeper);
        vm.expectRevert(FundingArbBot.NotAuthorized.selector);
        bot.close();

        // el whale de A cierra: skew A = −50 → −0,5 %/día; edge = −0,5 − (−0,5) = 0
        vm.prank(whaleA);
        a.closePosition(0);
        assertTrue(bot.shouldClose());
        vm.prank(keeper);
        uint256 back = bot.close();
        assertGt(back, 2 * MARGIN - 300e6);
    }

    function test_RebalanceSavesShortLeg() public {
        _open();
        oracle.setPrice(ETH, 2800e18); // +40 %: el short de A pierde 40k
        assertTrue(bot.needsRebalance());
        vm.prank(operator);
        bot.rebalance(false, 20_000e6); // B (ganador) → A
        assertFalse(bot.needsRebalance());
        oracle.setPrice(ETH, 3000e18); // +50 %: sin rebalanceo el short de A estaría liquidado
        assertFalse(a.isLiquidatable(address(bot)));
        assertApproxEqAbs(bot.totalEquity(), int256(CAPITAL - 100e6), 2);
    }

    /// @notice Riesgo central: el margen está aislado por venue. Sin rebalanceo, una suba fuerte
    ///         liquida el short aunque el long gane lo mismo; el bot pierde el equity remanente.
    function test_LegLiquidatedThenNakedLegClosedByAnyone() public {
        _open();
        oracle.setPrice(ETH, 2950e18);
        assertTrue(a.isLiquidatable(address(bot)));
        int256 eqA = a.equity(address(bot));
        vm.prank(keeper);
        a.liquidate(address(bot));
        assertTrue(bot.shouldClose()); // el long de B quedó desnudo
        vm.prank(keeper);
        bot.close();
        uint256 fin = usdc.balanceOf(address(bot));
        // pierde lo que quedaba en A (premio al liquidador + seguro), 2 fees de apertura y la de cierre de B (0,05 % de 147,5k)
        assertApproxEqAbs(fin, CAPITAL - 100e6 - uint256(eqA) - 73.75e6, 2);
        emit log_named_decimal_uint("Perdida por liquidacion (USDC)", CAPITAL - fin, 6);
    }

    function testFuzz_PriceNeutralAtOpen(uint256 px) public {
        px = bound(px, 1500e18, 2600e18);
        _open();
        int256 eq0 = bot.totalEquity();
        oracle.setPrice(ETH, px);
        assertApproxEqAbs(bot.totalEquity(), eq0, 2);
    }
}
