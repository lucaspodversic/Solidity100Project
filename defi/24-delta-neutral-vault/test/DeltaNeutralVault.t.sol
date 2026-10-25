// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeltaNeutralVault} from "../src/DeltaNeutralVault.sol";
import {PerpMarket} from "../src/perp/PerpMarket.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {OracleDex} from "../src/mocks/OracleDex.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Escenario: un mercado cargado de longs (skew +50 ETH) paga funding positivo; el
///         vault cobra ese funding estando neutral al precio.
contract DeltaNeutralVaultTest is Test {
    MockERC20 usdc;
    MockERC20 weth;
    PriceOracle oracle;
    PerpMarket perp;
    OracleDex dex;
    DeltaNeutralVault vault;

    address lp = makeAddr("lp");
    address degen = makeAddr("degen");
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new PriceOracle();
        oracle.setMaxAge(3650 days);
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);

        perp = new PerpMarket(usdc, oracle, address(weth), 0.01e18, 100e18);
        dex = new OracleDex(oracle);
        usdc.mint(address(dex), 10_000_000e6);
        weth.mint(address(dex), 10_000e18);

        // liquidez del perp
        usdc.mint(lp, 2_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(perp), type(uint256).max);
        perp.lpDeposit(2_000_000e6);
        vm.stopPrank();
        // especuladores long → funding positivo
        _trader(degen, 100_000e6, 50e18);

        vault = new DeltaNeutralVault(usdc, weth, perp, dex, oracle);
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _trader(address who, uint256 m, int256 size) internal {
        usdc.mint(who, m);
        vm.startPrank(who);
        usdc.approve(address(perp), type(uint256).max);
        perp.depositMargin(m);
        perp.trade(size, size > 0 ? type(uint256).max : 0);
        vm.stopPrank();
    }

    function _deposit(uint256 amt) internal {
        vm.prank(alice);
        vault.deposit(amt, alice);
    }

    function test_DepositDeploysDeltaNeutral() public {
        _deposit(30_000e6);
        // 10 % reserva = 3000; 27k desplegados: 18k spot (0,3 % fee DEX) y 9k margen
        assertEq(usdc.balanceOf(address(vault)), 3_000e6);
        assertEq(weth.balanceOf(address(vault)), 8.973e18);
        assertEq(perp.positionOf(address(vault)).size, -8.973e18);
        assertEq(vault.delta(), 0);
        assertApproxEqRel(vault.marginRatio(), 5_000, 0.01e18);
        // valor de liquidación: fee del DEX al entrar (54) y al salir (~54) + perp al entrar y salir (~9 + ~9)
        assertApproxEqAbs(vault.totalAssets(), 30_000e6 - 54e6 - 53.8e6 - 9e6 - 9e6, 1e6);
    }

    function test_PriceMovesDoNotChangeValue() public {
        _deposit(30_000e6);
        uint256 v0 = vault.totalAssets();
        oracle.setPrice(address(weth), 2400e18); // +20 %
        assertApproxEqRel(vault.totalAssets(), v0, 0.001e18); // < 0,1 %: solo cambian las fees de salida
        oracle.setPrice(address(weth), 1600e18); // −20 %
        assertApproxEqRel(vault.totalAssets(), v0, 0.001e18); // < 0,1 %: solo cambian las fees de salida
    }

    function test_CollectsFunding() public {
        _deposit(30_000e6);
        uint256 v0 = vault.totalAssets();
        int256 ratePerDay = perp.fundingRatePerDay(); // skew 50 − 8,97 ≈ 41 → ~0,41 %/día
        assertGt(ratePerDay, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 v1 = vault.totalAssets();
        // ≈ 8,973 ETH · 2000 · 0,41 % · 7 días ≈ 515 USDC
        uint256 expected = 8.973e18 * 2000 * uint256(ratePerDay) * 7 / 1e18 / 1e12;
        assertApproxEqRel(v1 - v0, expected, 0.01e18);
        emit log_named_uint("funding cobrado en 7 dias (USDC)", (v1 - v0) / 1e6);
    }

    function test_WithdrawBeyondReserveUnwindsProportionally() public {
        _deposit(30_000e6);
        vm.prank(alice);
        vault.withdraw(10_000e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 80_000e6);
        assertApproxEqAbs(vault.delta(), 0, 1e9); // sigue cubierto
        assertApproxEqRel(vault.marginRatio(), 5_000, 0.02e18);
    }

    function test_RedeemAll() public {
        _deposit(30_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        // funding de 30 días (~2,2k) − costos de entrada/salida (~130)
        assertGt(out, 31_500e6);
        emit log_named_uint("USDC al salir tras 30 dias", out / 1e6);
    }

    function test_RebalanceWhenShortNearLiquidation() public {
        _deposit(30_000e6);
        oracle.setPrice(address(weth), 2600e18); // +30 %: el short pierde ~5,4k de 9k de margen
        uint256 r = vault.marginRatio();
        assertLt(r, 2_500);
        vm.prank(keeper);
        vault.rebalance();
        assertApproxEqRel(vault.marginRatio(), 5_000, 0.01e18);
        assertEq(vault.delta(), 0);
    }

    function test_RebalanceNotNeededInsideBand() public {
        _deposit(30_000e6);
        uint256 r = vault.marginRatio();
        vm.expectRevert(abi.encodeWithSelector(DeltaNeutralVault.RebalanceNotNeeded.selector, r));
        vm.prank(keeper);
        vault.rebalance();
    }

    function test_UnwindWhenFundingFlipsNegative() public {
        _deposit(30_000e6);
        int256 f = perp.fundingRatePerDay();
        vm.expectRevert(abi.encodeWithSelector(DeltaNeutralVault.FundingStillPositive.selector, f));
        vm.prank(keeper);
        vault.unwindAll();

        // los longs se van y entra un short grande: ahora pagan los shorts
        vm.prank(degen);
        perp.closePosition(0);
        _trader(makeAddr("bear"), 100_000e6, -60e18);
        assertLt(perp.fundingRatePerDay(), 0);

        vm.prank(keeper);
        vault.unwindAll();
        assertFalse(vault.hedged());
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(perp.positionOf(address(vault)).size, 0);
        // nuevos depósitos quedan en USDC
        _deposit(1_000e6);
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    /// @notice Fuzz: con cualquier movimiento de precio razonable, el valor casi no cambia.
    function testFuzz_DeltaNeutral(uint256 px) public {
        px = bound(px, 1500e18, 2500e18);
        _deposit(30_000e6);
        uint256 v0 = vault.totalAssets();
        oracle.setPrice(address(weth), px);
        assertApproxEqRel(vault.totalAssets(), v0, 0.001e18); // < 0,1 %: solo cambian las fees de salida
    }
}
