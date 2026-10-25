// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PerpMarket} from "../src/PerpMarket.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Tests del perpetuo: PnL, funding por skew, márgenes, liquidación, deuda incobrable,
///         pool de LPs y conservación de la caja.
contract PerpMarketTest is Test {
    MockERC20 usdc;
    PriceOracle oracle;
    PerpMarket perp;
    address constant ETH = address(0xE7);

    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint256 constant P0 = 2000e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new PriceOracle();
        oracle.setMaxAge(3650 days);
        oracle.setPrice(ETH, P0);
        // funding máx 1 %/día al llegar a un skew de 100 ETH
        perp = new PerpMarket(usdc, oracle, ETH, 0.01e18, 100e18);

        _fund(lp, 1_000_000e6);
        vm.prank(lp);
        perp.lpDeposit(1_000_000e6);
        _fund(alice, 100_000e6);
        _fund(bob, 100_000e6);
    }

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(perp), type(uint256).max);
    }

    function _open(address who, uint256 m, int256 size) internal {
        vm.startPrank(who);
        perp.depositMargin(m);
        perp.trade(size, size > 0 ? type(uint256).max : 0);
        vm.stopPrank();
    }

    /// @dev Invariante de caja: todo USDC del contrato está asignado a alguien.
    function _assertCash() internal view {
        int256 sum = perp.margin(alice) + perp.margin(bob) + perp.lpCash() + int256(perp.insuranceFund());
        assertEq(int256(usdc.balanceOf(address(perp))), sum, "caja descuadrada");
    }

    // ---------------------------------------------------------------- PnL

    function test_LongProfit() public {
        _open(alice, 10_000e6, 10e18); // 10 ETH a 2000, 2x
        assertEq(perp.margin(alice), 10_000e6 - 10e6); // fee 0,05 % de 20k

        oracle.setPrice(ETH, 2200e18);
        assertEq(perp.equity(alice), 9_990e6 + 2_000e6);
        vm.prank(alice);
        perp.closePosition(0);
        // + 2000 de PnL − 11 de fee al cerrar (notional 22k)
        assertEq(perp.margin(alice), 9_990e6 + 2_000e6 - 11e6);
        _assertCash();
    }

    function test_ShortProfit_PartialCloseAndFlip() public {
        _open(bob, 10_000e6, -10e18);
        oracle.setPrice(ETH, 1800e18);
        vm.startPrank(bob);
        perp.trade(4e18, type(uint256).max); // cierra 4 → realiza 4·200 = 800
        assertEq(perp.positionOf(bob).size, -6e18);
        assertEq(perp.positionOf(bob).entryPrice, P0); // entrada no cambia al reducir
        perp.trade(10e18, type(uint256).max); // cierra 6 (+1200) y queda long 4 a 1800
        vm.stopPrank();
        PerpMarket.Position memory p = perp.positionOf(bob);
        assertEq(p.size, 4e18);
        assertEq(p.entryPrice, 1800e18);
        // fees: 10 + 0,05%·(4·1800) + 0,05%·(10·1800) = 10 + 3,6 + 9
        assertEq(perp.margin(bob), 10_000e6 + 2_000e6 - 10e6 - 3.6e6 - 9e6);
        _assertCash();
    }

    function test_AverageEntryPrice() public {
        _open(alice, 10_000e6, 2e18);
        oracle.setPrice(ETH, 2300e18);
        vm.prank(alice);
        perp.trade(1e18, type(uint256).max);
        assertEq(perp.positionOf(alice).entryPrice, 2100e18); // (2·2000 + 1·2300)/3
    }

    // ------------------------------------------------------------ funding

    function test_Funding_SkewBased_LongsPayPool() public {
        _open(alice, 10_000e6, 10e18); // skew +10 → 10 % del máximo = 0,1 %/día
        assertApproxEqAbs(perp.fundingRatePerDay(), 0.001e18, 1e6);
        int256 lpBefore = perp.lpCash();
        int256 mBefore = perp.margin(alice);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        // 0,1 % de 20k = 20 USDC pendientes
        assertApproxEqAbs(perp.equity(alice), mBefore - 20e6, 1);

        vm.prank(alice);
        perp.withdrawMargin(1e6); // fuerza el settle
        assertApproxEqAbs(perp.margin(alice), mBefore - 20e6 - 1e6, 1);
        assertApproxEqAbs(perp.lpCash() - lpBefore, 20e6, 1);
        _assertCash();
    }

    function test_Funding_BalancedMarketIsZero_ShortsPayWhenSkewNegative() public {
        _open(alice, 10_000e6, 10e18);
        _open(bob, 10_000e6, -10e18);
        assertEq(perp.currentFundingRate(), 0);

        vm.prank(alice);
        perp.closePosition(0); // ahora skew −10 → pagan los shorts
        assertLt(perp.currentFundingRate(), 0);
        int256 m = perp.equity(bob);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertApproxEqAbs(perp.equity(bob), m - 20e6, 1);
    }

    function test_Funding_CappedAtMax() public {
        _open(alice, 50_000e6, 150e18); // skew 150 > skewScale
        assertEq(perp.currentFundingRate(), perp.maxFundingRatePerSecond());
    }

    function test_PoolValueTracksOpenPnlAndFunding() public {
        int256 pv0 = perp.poolValue();
        _open(alice, 10_000e6, 10e18);
        int256 pv1 = perp.poolValue(); // + 8 de fee a LPs (80 % de 10)
        assertEq(pv1 - pv0, 8e6);
        oracle.setPrice(ETH, 2100e18);
        assertEq(perp.poolValue(), pv1 - 1_000e6); // el pool está short 10 ETH
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertGt(perp.poolValue(), pv1 - 1_000e6); // gana el funding (~21)
    }

    // ------------------------------------------------------------ márgenes

    function test_InitialMarginEnforced() public {
        vm.startPrank(alice);
        perp.depositMargin(1_000e6);
        vm.expectPartialRevert(PerpMarket.InsufficientMargin.selector);
        perp.trade(6e18, type(uint256).max); // 12k notional con 1k = 12x > 10x
        perp.trade(4e18, type(uint256).max); // 8x ok
        vm.expectPartialRevert(PerpMarket.InsufficientMargin.selector);
        perp.withdrawMargin(300e6); // quedaría < 10 %
        vm.stopPrank();
    }

    function test_SlippageProtection() public {
        vm.startPrank(alice);
        perp.depositMargin(10_000e6);
        vm.expectRevert(abi.encodeWithSelector(PerpMarket.PriceSlippage.selector, P0, 1999e18));
        perp.trade(1e18, 1999e18);
        vm.expectRevert(abi.encodeWithSelector(PerpMarket.PriceSlippage.selector, P0, 2001e18));
        perp.trade(-1e18, 2001e18);
        vm.stopPrank();
    }

    function test_ReducingAlwaysAllowedEvenUnderwater() public {
        _open(alice, 1_000e6, 4e18);
        oracle.setPrice(ETH, 1900e18); // equity 596 < IM 760, pero > MM
        vm.prank(alice);
        perp.trade(-1e18, 0); // reducir riesgo no exige margen inicial
        assertEq(perp.positionOf(alice).size, 3e18);
    }

    // --------------------------------------------------------- liquidación

    function test_Liquidation_RewardAndInsurance() public {
        _open(alice, 1_000e6, 4e18); // margen 996 tras fee
        uint256 lp_ = perp.liquidationPrice(alice);
        assertApproxEqRel(lp_, 1843.15e18, 0.001e18);

        oracle.setPrice(ETH, 1850e18);
        assertFalse(perp.isLiquidatable(alice));
        vm.expectRevert(PerpMarket.NotLiquidatable.selector);
        perp.liquidate(alice);

        oracle.setPrice(ETH, 1840e18); // equity 356 < 5 %·7360 = 368
        uint256 insBefore = perp.insuranceFund();
        vm.prank(keeper);
        uint256 reward = perp.liquidate(alice);
        assertEq(reward, 73.6e6); // 1 % del notional
        assertEq(usdc.balanceOf(keeper), 73.6e6);
        assertEq(perp.insuranceFund() - insBefore, 356e6 - 73.6e6);
        assertEq(perp.positionOf(alice).size, 0);
        assertEq(perp.margin(alice), 0);
        assertEq(perp.longOI(), 0);
        _assertCash();
    }

    function test_Liquidation_BadDebtHitsInsuranceThenLPs() public {
        _open(alice, 1_000e6, 4e18);
        oracle.setPrice(ETH, 1700e18); // equity 996 − 1200 = −204
        uint256 ins = perp.insuranceFund(); // 0,8 de fees
        int256 lpCashBefore = perp.lpCash();
        vm.prank(keeper);
        uint256 reward = perp.liquidate(alice);
        assertEq(reward, 0); // no queda nada para pagar al liquidador
        assertEq(perp.insuranceFund(), 0);
        // El pool cobró 1200 de PnL pero solo existían 996: pierde 204 − seguro
        assertEq(perp.lpCash() - lpCashBefore, 1_200e6 - (204e6 - int256(ins)));
        _assertCash();
    }

    // ---------------------------------------------------------- pool / LPs

    function test_SkewCapProtectsSmallPool() public {
        PerpMarket small = new PerpMarket(usdc, oracle, ETH, 0.01e18, 100e18);
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(small), type(uint256).max);
        small.lpDeposit(10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(small), type(uint256).max);
        small.depositMargin(10_000e6);
        vm.expectRevert(PerpMarket.SkewCapExceeded.selector);
        small.trade(10e18, type(uint256).max); // 20k de skew con 10k de pool
        small.trade(4e18, type(uint256).max); // 8k ok
        vm.stopPrank();
        // el LP no puede retirar dejando el skew sin respaldo
        uint256 shares = small.lpShares(address(this));
        vm.expectRevert(PerpMarket.SkewCapExceeded.selector);
        small.lpWithdraw(shares / 2);
    }

    function test_LpEarnsWhenTradersLose() public {
        _open(alice, 10_000e6, 10e18);
        oracle.setPrice(ETH, 1900e18);
        vm.prank(alice);
        perp.closePosition(0);
        uint256 shares = perp.lpShares(lp);
        vm.prank(lp);
        uint256 out = perp.lpWithdraw(shares);
        // 1000 de pérdida del trader + 80 % de fees (10 + 9,5)
        assertApproxEqAbs(out, 1_000_000e6 + 1_000e6 + 15.6e6, 2);
    }

    // ---------------------------------------------------------------- fuzz

    /// @notice Conservación: con cualquier secuencia precio/tiempo, la caja cuadra y el
    ///         poolValue refleja exactamente lo que queda tras cerrar todo.
    function testFuzz_CashConservation(uint64 pxA, uint64 pxB, uint32 dt, int8 sa, int8 sb) public {
        uint256 pa = bound(uint256(pxA), 1500, 2500) * 1e18;
        uint256 pb = bound(uint256(pxB), 1600, 2400) * 1e18;
        int256 sizeA = int256(bound(int256(sa), -20, 20)) * 1e17; // ±2 ETH
        int256 sizeB = int256(bound(int256(sb), -20, 20)) * 1e17;
        vm.assume(sizeA != 0 && sizeB != 0);

        oracle.setPrice(ETH, pa);
        _open(alice, 5_000e6, sizeA);
        _open(bob, 5_000e6, sizeB);
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 30 days));
        oracle.setPrice(ETH, pb);
        int256 pvOpen = perp.poolValue();

        vm.prank(alice);
        perp.closePosition(sizeA > 0 ? 0 : type(uint256).max);
        vm.prank(bob);
        perp.closePosition(sizeB > 0 ? 0 : type(uint256).max);
        _assertCash();
        assertEq(perp.longOI() + perp.shortOI(), 0);
        // tras cerrar, poolValue == lpCash, y solo difiere del valor "abierto" por las
        // fees de cierre y el polvo de redondeo (siempre a favor del pool)
        assertEq(perp.poolValue(), perp.lpCash());
        assertGe(perp.poolValue(), pvOpen - 2);
    }
}
