// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LendingPool} from "../src/protocol/LendingPool.sol";
import {JumpRateModel} from "../src/protocol/JumpRateModel.sol";
import {PriceOracle} from "../src/protocol/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {HealthFactorLens} from "../src/HealthFactorLens.sol";

/// @title Tests del dashboard de health factor
contract HealthFactorLensTest is Test {
    LendingPool pool;
    PriceOracle oracle;
    HealthFactorLens lens;
    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 wbtc;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address nobody = makeAddr("nobody");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        oracle = new PriceOracle();
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(wbtc), 60_000e18);
        JumpRateModel m = new JumpRateModel(0, 0.04e18, 0.75e18, 0.8e18);
        pool = new LendingPool(oracle, makeAddr("treasury"));
        pool.listMarket(address(weth), 0.75e18, 0.8e18, 0.05e18, 0.1e18, m);
        pool.listMarket(address(wbtc), 0.7e18, 0.75e18, 0.05e18, 0.1e18, m);
        pool.listMarket(address(usdc), 0.8e18, 0.85e18, 0.05e18, 0.1e18, m);
        lens = new HealthFactorLens(pool);

        address lp = makeAddr("lp");
        _deposit(lp, usdc, 1_000_000e6);
        // Alice: 10 ETH (20k) → debe 12k USDC
        _deposit(alice, weth, 10e18);
        vm.prank(alice);
        pool.borrow(address(usdc), 12_000e6);
        // Bob: 5 ETH + 0,5 BTC (10k + 30k) → debe 25k
        _deposit(bob, weth, 5e18);
        _deposit(bob, wbtc, 0.5e8);
        vm.prank(bob);
        pool.borrow(address(usdc), 25_000e6);
    }

    function _deposit(address u, MockERC20 t, uint256 amt) internal {
        t.mint(u, amt);
        vm.startPrank(u);
        t.approve(address(pool), amt);
        pool.deposit(address(t), amt);
        vm.stopPrank();
    }

    function test_DashboardTotals() public view {
        HealthFactorLens.Dashboard memory d = lens.dashboard(alice);
        assertEq(d.lines.length, 3);
        assertEq(d.collateralUsd, 20_000e18);
        assertEq(d.debtUsd, 12_000e18);
        assertEq(d.borrowLimitUsd, 15_000e18);
        assertEq(d.availableToBorrowUsd, 3_000e18);
        assertApproxEqAbs(d.healthFactor, 1.3333e18, 1e14); // 16k/12k
        assertEq(d.ltvUsed, 0.6e18);
        assertEq(uint256(d.risk), uint256(HealthFactorLens.Risk.Warning));
        assertEq(d.lines[0].supplied, 10e18);
        assertEq(d.lines[2].borrowed, 12_000e6);
    }

    function test_DashboardMatchesPool() public view {
        assertEq(lens.dashboard(bob).healthFactor, pool.healthFactor(bob));
    }

    function test_RiskBuckets() public view {
        assertEq(uint256(lens.riskOf(type(uint256).max)), uint256(HealthFactorLens.Risk.NoDebt));
        assertEq(uint256(lens.riskOf(2e18)), uint256(HealthFactorLens.Risk.Safe));
        assertEq(uint256(lens.riskOf(1.2e18)), uint256(HealthFactorLens.Risk.Warning));
        assertEq(uint256(lens.riskOf(1.05e18)), uint256(HealthFactorLens.Risk.Danger));
        assertEq(uint256(lens.riskOf(0.99e18)), uint256(HealthFactorLens.Risk.Liquidatable));
        assertEq(uint256(lens.dashboard(nobody).risk), uint256(HealthFactorLens.Risk.NoDebt));
    }

    function test_LiquidationPriceSingleCollateral() public {
        // 10 · P · 0,8 = 12000 → P = 1500
        uint256 p = lens.liquidationPrice(alice, address(weth));
        assertEq(p, 1500e18);
        // Verificación: a ese precio HF = 1, apenas debajo es liquidable
        oracle.setPrice(address(weth), p);
        assertEq(pool.healthFactor(alice), 1e18);
        oracle.setPrice(address(weth), p - 1e18);
        assertLt(pool.healthFactor(alice), 1e18);
    }

    function test_LiquidationPriceMultiCollateral() public view {
        // Bob: BTC cubre 30k·0,75 = 22,5k; falta 2,5k → 5·P·0,8 = 2500 → P = 625
        assertEq(lens.liquidationPrice(bob, address(weth)), 625e18);
        // BTC: ETH cubre 8k; faltan 17k → 0,5·P·0,75 = 17000 → P = 45 333,33
        assertApproxEqAbs(lens.liquidationPrice(bob, address(wbtc)), 45_333.333e18, 1e15);
    }

    function test_LiquidationPriceEdgeCases() public view {
        assertEq(lens.liquidationPrice(nobody, address(weth)), 0); // sin deuda
        assertEq(lens.liquidationPrice(alice, address(wbtc)), 0); // no tiene BTC: su ETH ya cubre la deuda
    }

    function test_StressTest() public view {
        uint256[] memory drops = new uint256[](4);
        drops[0] = 0;
        drops[1] = 1000;
        drops[2] = 2500;
        drops[3] = 5000;
        uint256[] memory hfs = lens.stressTest(alice, address(weth), drops);
        assertApproxEqAbs(hfs[0], 1.3333e18, 1e14);
        assertEq(hfs[1], 1.2e18); // 18000·0,8/12000
        assertEq(hfs[2], 1e18); // −25 % = 1500 = precio de liquidación
        assertLt(hfs[3], 1e18);
    }

    function test_HfAtPriceMatchesRealPriceChange() public {
        uint256 sim = lens.hfAtPrice(bob, address(wbtc), 50_000e18);
        oracle.setPrice(address(wbtc), 50_000e18);
        assertEq(sim, pool.healthFactor(bob));
    }

    function test_MaxBorrowIsExact() public {
        uint256 mb = lens.maxBorrow(alice, address(usdc));
        assertEq(mb, 3_000e6);
        vm.startPrank(alice);
        pool.borrow(address(usdc), mb);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(address(usdc), 1);
        vm.stopPrank();
    }

    function test_MaxWithdrawIsSafe() public {
        uint256 mw = lens.maxWithdraw(alice, address(weth));
        // 16000 − 12000 = 4000 USD de margen / (2000·0,8) = 2,5 ETH
        assertEq(mw, 2.5e18);
        vm.prank(alice);
        pool.withdraw(address(weth), mw);
        assertGe(pool.healthFactor(alice), 1e18);
    }

    function test_Batch() public view {
        address[] memory us = new address[](3);
        us[0] = alice;
        us[1] = bob;
        us[2] = nobody;
        HealthFactorLens.Summary[] memory s = lens.batch(us);
        assertEq(s[0].debtUsd, 12_000e18);
        assertEq(uint256(s[2].risk), uint256(HealthFactorLens.Risk.NoDebt));
        assertEq(s[1].healthFactor, pool.healthFactor(bob));
    }

    /// @notice Fuzz: hfAtPrice coincide con el HF real tras cambiar el precio.
    function testFuzz_HfAtPrice(uint256 price) public {
        price = bound(price, 100e18, 10_000e18);
        uint256 sim = lens.hfAtPrice(bob, address(weth), price);
        oracle.setPrice(address(weth), price);
        assertEq(sim, pool.healthFactor(bob));
    }
}
