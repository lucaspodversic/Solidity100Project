// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {JumpRateModel} from "../src/JumpRateModel.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests del protocolo de préstamos
contract LendingPoolTest is Test {
    LendingPool pool;
    PriceOracle oracle;
    JumpRateModel model;
    MockERC20 usdc;
    MockERC20 weth;
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");
    address treasury = makeAddr("treasury");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        oracle = new PriceOracle();
        _prices(2000e18);
        // base 0 %, 4 % hasta el kink de 80 %, +75 % por encima
        model = new JumpRateModel(0, 0.04e18, 0.75e18, 0.8e18);
        pool = new LendingPool(oracle, treasury);
        pool.listMarket(address(weth), 0.75e18, 0.8e18, 0.05e18, 0.1e18, model);
        pool.listMarket(address(usdc), 0.8e18, 0.85e18, 0.05e18, 0.1e18, model);

        usdc.mint(lender, 1_000_000e6);
        weth.mint(borrower, 10e18);
        usdc.mint(borrower, 100_000e6);
        usdc.mint(liquidator, 1_000_000e6);
        _approve(lender);
        _approve(borrower);
        _approve(liquidator);

        vm.prank(lender);
        pool.deposit(address(usdc), 1_000_000e6);
        vm.prank(borrower);
        pool.deposit(address(weth), 10e18);
    }

    function _prices(uint256 ethPrice) internal {
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), ethPrice);
    }

    function _approve(address u) internal {
        vm.startPrank(u);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function test_BorrowWithinLtv() public {
        vm.prank(borrower);
        pool.borrow(address(usdc), 15_000e6); // 10 ETH · 2000 · 0,75 = 15000
        assertEq(usdc.balanceOf(borrower), 115_000e6);
        assertApproxEqRel(pool.healthFactor(borrower), 1.0667e18, 0.001e18); // 16000/15000
    }

    function test_BorrowAboveLtvReverts() public {
        vm.prank(borrower);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrow(address(usdc), 15_001e6);
    }

    function test_InterestAccruesAndSuppliersEarn() public {
        vm.prank(borrower);
        pool.borrow(address(usdc), 15_000e6);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 365 days);
        _prices(2000e18);
        pool.accrue(address(usdc));
        // U = 1,5 % -> tasa = 4 % · 0,015/0,8 = 0,075 % anual
        uint256 debt = pool.borrowBalance(address(usdc), borrower);
        assertApproxEqRel(debt, 15_011.25e6, 0.001e18);
        uint256 interest = debt - 15_000e6;
        // Depositante gana el 90 %; tesorería el 10 %
        uint256 lenderGain = pool.supplyBalance(address(usdc), lender) - 1_000_000e6;
        uint256 treasuryGain = pool.supplyBalance(address(usdc), treasury);
        assertApproxEqRel(lenderGain, (interest * 9) / 10, 0.01e18);
        assertApproxEqRel(treasuryGain, interest / 10, 0.01e18);
    }

    function test_RepayFullClearsDebt() public {
        vm.prank(borrower);
        pool.borrow(address(usdc), 10_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _prices(2000e18);
        vm.prank(borrower);
        pool.repay(address(usdc), type(uint256).max, borrower);
        assertEq(pool.borrowBalance(address(usdc), borrower), 0);
        assertEq(pool.healthFactor(borrower), type(uint256).max);
    }

    function test_WithdrawBlockedIfUnhealthy() public {
        vm.startPrank(borrower);
        pool.borrow(address(usdc), 15_000e6);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.withdraw(address(weth), 1e18);
        vm.stopPrank();
    }

    function test_LiquidationAfterPriceDrop() public {
        vm.prank(borrower);
        pool.borrow(address(usdc), 15_000e6);
        _prices(1800e18); // HF = 18000·0,8/15000 = 0,96
        assertLt(pool.healthFactor(borrower), 1e18);

        vm.prank(liquidator);
        vm.expectRevert(LendingPool.TooMuchRepay.selector);
        pool.liquidate(address(usdc), address(weth), borrower, 7_501e6);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = pool.liquidate(address(usdc), address(weth), borrower, 7_500e6);
        assertEq(repaid, 7_500e6);
        // 7500 · 1,05 / 1800 = 4,375 ETH
        assertApproxEqRel(seized, 4.375e18, 1e12);
        assertEq(weth.balanceOf(liquidator), seized);
        // La posición queda más sana
        assertGt(pool.healthFactor(borrower), 1e18);
    }

    function test_CannotLiquidateHealthy() public {
        vm.prank(borrower);
        pool.borrow(address(usdc), 10_000e6);
        vm.prank(liquidator);
        vm.expectRevert(LendingPool.HealthyPosition.selector);
        pool.liquidate(address(usdc), address(weth), borrower, 1_000e6);
    }

    function test_LiquidationCappedByCollateral() public {
        vm.prank(borrower);
        pool.borrow(address(usdc), 15_000e6);
        _prices(1000e18); // colateral 10.000 USD vs deuda 15.000: insolvente
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = pool.liquidate(address(usdc), address(weth), borrower, 7_500e6);
        // Sólo hay 10 ETH; 7500·1,05/1000 = 7,875 ETH entra completo
        assertApproxEqRel(seized, 7.875e18, 1e12);
        assertEq(repaid, 7_500e6);
    }

    function test_DonationDoesNotChangeAccounting() public {
        uint256 before = pool.supplyBalance(address(usdc), lender);
        usdc.mint(address(pool), 1_000_000e6); // donación directa
        assertEq(pool.supplyBalance(address(usdc), lender), before);
        (uint256 util,,) = pool.marketRates(address(usdc));
        assertEq(util, 0);
    }

    function test_StaleOracleBlocksBorrow() public {
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.StalePrice.selector, address(weth)));
        pool.borrow(address(usdc), 1_000e6);
    }

    function test_InsufficientLiquidity() public {
        vm.prank(borrower);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(address(weth), 11e18);
    }

    function test_BadParamsListing() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        vm.expectRevert(LendingPool.BadParams.selector);
        pool.listMarket(address(x), 0.9e18, 0.8e18, 0.05e18, 0.1e18, model); // ltv > umbral
        vm.expectRevert(LendingPool.BadParams.selector);
        pool.listMarket(address(x), 0.9e18, 0.97e18, 0.05e18, 0.1e18, model); // 0,97·1,05 ≥ 1
    }

    function test_KinkRates() public view {
        assertEq(model.borrowRate(0.8e18), 0.04e18);
        assertEq(model.borrowRate(0.9e18), 0.04e18 + 0.375e18);
        assertEq(model.borrowRate(1e18), 0.79e18);
    }

    /// @notice Fuzz: el pool siempre es solvente: liquidez + deuda ≥ depósitos.
    function testFuzz_Solvency(uint256 amt, uint256 dt) public {
        amt = bound(amt, 1e6, 15_000e6);
        dt = bound(dt, 1, 5 * 365 days);
        vm.prank(borrower);
        pool.borrow(address(usdc), amt);
        vm.warp(vm.getBlockTimestamp() + dt);
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 1_000_000e18); // evitamos que la deuda supere el colateral
        pool.accrue(address(usdc));
        (,,,,,,,,,, uint256 tss, uint256 tsb, uint256 cash) = pool.markets(address(usdc));
        (,,,,,,, , uint256 sIdx, uint256 bIdx,,,) = pool.markets(address(usdc));
        uint256 supplied = (tss * sIdx) / 1e27;
        uint256 debt = (tsb * bIdx) / 1e27;
        assertGe(cash + debt + 1, supplied, "solvencia");
        // Y el deudor puede repagar todo
        vm.prank(borrower);
        pool.repay(address(usdc), type(uint256).max, borrower);
        assertEq(pool.borrowBalance(address(usdc), borrower), 0);
    }

    /// @notice Fuzz: depositar y retirar inmediatamente nunca da ganancia.
    function testFuzz_NoFreeMoney(uint256 amt) public {
        amt = bound(amt, 1, 100_000e6);
        vm.startPrank(borrower);
        pool.deposit(address(usdc), amt);
        uint256 got = pool.withdraw(address(usdc), type(uint256).max);
        vm.stopPrank();
        assertLe(got, amt);
    }
}
