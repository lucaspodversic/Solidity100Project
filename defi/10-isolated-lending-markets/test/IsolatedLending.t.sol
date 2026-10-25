// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IsolatedLending} from "../src/IsolatedLending.sol";
import {LinearIrm} from "../src/LinearIrm.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests de mercados aislados
/// @dev Escala del oráculo: precio de 1 wei de colateral en unidades mínimas de USDC · 1e36.
///      WETH a 2000 USD → 2000e6 · 1e36 / 1e18 = 2000e24.
contract IsolatedLendingTest is Test {
    IsolatedLending lend;
    LinearIrm irm;
    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 meme;
    MockOracle ethOracle;
    MockOracle memeOracle;
    IsolatedLending.MarketParams ethMkt;
    IsolatedLending.MarketParams memeMkt;

    address lenderA = makeAddr("lenderA"); // presta en el mercado WETH (seguro)
    address lenderB = makeAddr("lenderB"); // presta en el mercado MEME (riesgoso)
    address bob = makeAddr("bob");
    address liq = makeAddr("liq");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        meme = new MockERC20("MEME", "MEME", 18);
        ethOracle = new MockOracle();
        memeOracle = new MockOracle();
        ethOracle.setPrice(2000e24);
        memeOracle.setPrice(1e24); // 1 USD
        lend = new IsolatedLending();
        irm = new LinearIrm(0.02e18, 0.1e18);
        lend.enableIrm(address(irm));
        lend.enableLltv(0.86e18);
        lend.enableLltv(0.5e18);
        ethMkt = IsolatedLending.MarketParams(address(usdc), address(weth), address(ethOracle), address(irm), 0.86e18);
        memeMkt = IsolatedLending.MarketParams(address(usdc), address(meme), address(memeOracle), address(irm), 0.5e18);
        lend.createMarket(ethMkt);
        lend.createMarket(memeMkt);

        address[4] memory us = [lenderA, lenderB, bob, liq];
        for (uint256 i; i < 4; i++) {
            usdc.mint(us[i], 1_000_000e6);
            weth.mint(us[i], 100e18);
            meme.mint(us[i], 1_000_000e18);
            vm.startPrank(us[i]);
            usdc.approve(address(lend), type(uint256).max);
            weth.approve(address(lend), type(uint256).max);
            meme.approve(address(lend), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lenderA);
        lend.supply(ethMkt, 100_000e6, lenderA);
        vm.prank(lenderB);
        lend.supply(memeMkt, 100_000e6, lenderB);
    }

    function test_PermissionlessCreationNeedsEnabledParams() public {
        IsolatedLending.MarketParams memory p = ethMkt;
        p.lltv = 0.99e18;
        vm.prank(bob);
        vm.expectRevert(IsolatedLending.NotEnabled.selector);
        lend.createMarket(p);
        vm.expectRevert(IsolatedLending.MarketExists.selector);
        lend.createMarket(ethMkt);
    }

    function test_BorrowUpToLltv() public {
        vm.startPrank(bob);
        lend.supplyCollateral(ethMkt, 1e18, bob); // 2000 USD · 0,86 = 1720
        lend.borrow(ethMkt, 1_720e6, bob);
        vm.expectRevert(IsolatedLending.Unhealthy.selector);
        lend.borrow(ethMkt, 1e6, bob);
        vm.stopPrank();
    }

    function test_InterestAccrues() public {
        vm.startPrank(bob);
        lend.supplyCollateral(ethMkt, 10e18, bob);
        lend.borrow(ethMkt, 10_000e6, bob);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        lend.accrueInterest(ethMkt);
        // U = 10 % -> tasa 2 % + 1 % = 3 %; compuesto ≈ 3,045 %
        assertApproxEqRel(lend.borrowAssetsOf(ethMkt, bob), 10_304.5e6, 0.001e18);
        assertApproxEqRel(lend.supplyAssetsOf(ethMkt, lenderA), 100_304.5e6, 0.001e18);
    }

    function test_LiquidationWithIncentive() public {
        vm.startPrank(bob);
        lend.supplyCollateral(ethMkt, 1e18, bob);
        lend.borrow(ethMkt, 1_700e6, bob);
        vm.stopPrank();
        ethOracle.setPrice(1900e24); // 1900·0,86 = 1634 < 1700
        assertFalse(lend.isHealthy(ethMkt, bob));
        uint256 lif = lend.liquidationIncentive(0.86e18);
        assertApproxEqRel(lif, 1.0438e18, 0.001e18);
        vm.prank(liq);
        (uint256 repaid, uint256 bad) = lend.liquidate(ethMkt, bob, 0.5e18);
        // 0,5 ETH · 1900 / 1,0438 ≈ 910 USDC
        assertApproxEqRel(repaid, 910.1e6, 0.001e18);
        assertEq(bad, 0);
    }

    function test_HealthyCannotBeLiquidated() public {
        vm.startPrank(bob);
        lend.supplyCollateral(ethMkt, 1e18, bob);
        lend.borrow(ethMkt, 1_000e6, bob);
        vm.stopPrank();
        vm.prank(liq);
        vm.expectRevert(IsolatedLending.Healthy.selector);
        lend.liquidate(ethMkt, bob, 0.1e18);
    }

    /// @notice El caso central: un colateral colapsa; sólo sus prestamistas pierden.
    function test_IsolationBadDebtStaysInMarket() public {
        vm.startPrank(bob);
        lend.supplyCollateral(memeMkt, 100_000e18, bob); // 100k USD de MEME
        lend.borrow(memeMkt, 50_000e6, bob); // LLTV 50 %
        vm.stopPrank();
        memeOracle.setPrice(0.1e24); // MEME cae 90 %: colateral 10k vs deuda 50k
        vm.prank(liq);
        (, uint256 bad) = lend.liquidate(memeMkt, bob, type(uint256).max);
        assertGt(bad, 40_000e6, "deuda incobrable reconocida");
        // Los prestamistas del mercado MEME absorben la pérdida...
        assertLt(lend.supplyAssetsOf(memeMkt, lenderB), 60_000e6);
        // ...pero los del mercado WETH quedan intactos.
        assertEq(lend.supplyAssetsOf(ethMkt, lenderA), 100_000e6);
        vm.prank(lenderA);
        uint256 got = lend.withdraw(ethMkt, type(uint256).max, lenderA);
        assertEq(got, 100_000e6);
    }

    /// @notice La liquidez de un mercado no puede usarse en otro.
    function test_CannotBorrowOtherMarketsLiquidity() public {
        vm.startPrank(bob);
        lend.supplyCollateral(ethMkt, 100e18, bob); // 200k USD
        vm.expectRevert(IsolatedLending.InsufficientLiquidity.selector);
        lend.borrow(ethMkt, 100_001e6, bob); // el contrato tiene 200k USDC, el mercado 100k
        vm.stopPrank();
    }

    function test_WithdrawLimitedByUtilization() public {
        vm.startPrank(bob);
        lend.supplyCollateral(ethMkt, 100e18, bob);
        lend.borrow(ethMkt, 90_000e6, bob);
        vm.stopPrank();
        vm.prank(lenderA);
        vm.expectRevert(IsolatedLending.InsufficientLiquidity.selector);
        lend.withdraw(ethMkt, type(uint256).max, lenderA);
    }

    function test_RepayAndWithdrawCollateral() public {
        vm.startPrank(bob);
        lend.supplyCollateral(ethMkt, 1e18, bob);
        lend.borrow(ethMkt, 1_000e6, bob);
        vm.expectRevert(IsolatedLending.Unhealthy.selector);
        lend.withdrawCollateral(ethMkt, 1e18, bob);
        lend.repay(ethMkt, type(uint256).max, bob);
        lend.withdrawCollateral(ethMkt, 1e18, bob);
        vm.stopPrank();
        assertEq(weth.balanceOf(bob), 100e18);
    }

    /// @notice Ataque de inflación de shares en un mercado recién creado.
    function test_InflationAttackMitigated() public {
        MockOracle o = new MockOracle();
        o.setPrice(1e24);
        IsolatedLending.MarketParams memory p =
            IsolatedLending.MarketParams(address(usdc), address(meme), address(o), address(irm), 0.5e18);
        lend.createMarket(p);
        // El atacante deposita 1 wei. Donar tokens directo al contrato no sirve (no se usa
        // balanceOf) y las shares virtuales evitan que el redondeo le robe al siguiente.
        vm.prank(liq);
        lend.supply(p, 1, liq);
        vm.prank(bob);
        uint256 shares = lend.supply(p, 1_000e6, bob);
        assertGt(shares, 0);
        assertApproxEqRel(lend.supplyAssetsOf(p, bob), 1_000e6, 1e12);
    }

    /// @notice Fuzz: supply + withdraw inmediato no genera ganancia.
    function testFuzz_SupplyWithdrawNoProfit(uint256 amt) public {
        amt = bound(amt, 1, 500_000e6);
        vm.startPrank(bob);
        lend.supply(ethMkt, amt, bob);
        uint256 got = lend.withdraw(ethMkt, type(uint256).max, bob);
        vm.stopPrank();
        assertLe(got, amt);
    }

    /// @notice Fuzz: borrow + repay inmediato cuesta ≥ lo prestado.
    function testFuzz_BorrowRepayNoProfit(uint256 amt) public {
        amt = bound(amt, 1, 50_000e6);
        vm.startPrank(bob);
        lend.supplyCollateral(ethMkt, 100e18, bob);
        uint256 before = usdc.balanceOf(bob);
        lend.borrow(ethMkt, amt, bob);
        lend.repay(ethMkt, type(uint256).max, bob);
        vm.stopPrank();
        assertLe(usdc.balanceOf(bob), before);
    }
}
