// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MultiStrategyVault} from "../src/MultiStrategyVault.sol";
import {IStrategy} from "../src/IStrategy.sol";
import {MockStrategy} from "../src/mocks/MockStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests del vault multi-estrategia
/// @notice Escenario base: alice deposita 100 000 USDC. Estrategias:
///         A = 8 % APY, tope 50 %; B = 5 % APY, tope 60 %; C = 3 % APY, tope 100 %.
///         Tras `allocate()`: A 50k, B 45k, C 0, 5k ocioso (reserva 5 %).
contract MultiStrategyVaultTest is Test {
    MockERC20 usdc;
    MultiStrategyVault vault;
    MockStrategy A;
    MockStrategy B;
    MockStrategy C;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MultiStrategyVault(IERC20(address(usdc)), treasury);
        A = new MockStrategy(address(usdc), address(vault), 800);
        B = new MockStrategy(address(usdc), address(vault), 500);
        C = new MockStrategy(address(usdc), address(vault), 300);
        vault.addStrategy(A, 5_000);
        vault.addStrategy(B, 6_000);
        vault.addStrategy(C, 10_000);
        address[2] memory us = [alice, attacker];
        for (uint256 i; i < 2; i++) {
            usdc.mint(us[i], 1_000_000e6);
            vm.prank(us[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
        vm.prank(alice);
        vault.deposit(100_000e6, alice);
        vault.allocate();
    }

    function _debt(IStrategy s) internal view returns (uint256 d) {
        (,, d,) = vault.strategies(s);
    }

    function test_AllocationByApyAndCaps() public view {
        assertEq(_debt(A), 50_000e6, "A llena hasta su tope");
        assertEq(_debt(B), 45_000e6, "B recibe el resto hasta la reserva");
        assertEq(_debt(C), 0);
        assertEq(vault.idle(), 5_000e6, "5 % de reserva");
        assertEq(vault.totalAssets(), 100_000e6);
        assertEq(vault.weightedApy(), 625, "(50k*8% + 45k*5%)/100k");
    }

    function test_ReallocatesWhenApyChanges() public {
        C.setApy(1_000);
        vault.allocate();
        assertEq(_debt(C), 95_000e6);
        assertEq(_debt(A), 0);
        assertEq(_debt(B), 0);
        assertEq(vault.totalAssets(), 100_000e6, "reasignar no crea ni destruye valor");
    }

    function test_ReportGainChargesFeeAndUnlocksLinearly() public {
        A.simulateGain(5_000e6);
        (uint256 gain, uint256 loss) = vault.report(A);
        assertEq(gain, 5_000e6);
        assertEq(loss, 0);
        assertEq(vault.totalAssets(), 100_000e6, "ganancia bloqueada");
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertApproxEqAbs(vault.totalAssets(), 102_500e6, 1, "mitad liberada");
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(vault.totalAssets(), 105_000e6);
        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        uint256 treasAssets = vault.convertToAssets(vault.balanceOf(treasury));
        assertApproxEqRel(aliceAssets, 104_477e6, 1e14, "105k / 1,005");
        assertApproxEqRel(treasAssets, 522e6, 2e15, "10 % de fee en shares");
    }

    function test_ReportLossIsImmediate() public {
        B.simulateLoss(9_000e6);
        (, uint256 loss) = vault.report(B);
        assertEq(loss, 9_000e6);
        assertEq(vault.totalAssets(), 91_000e6, "la perdida no se demora");
    }

    function test_LossEatsLockedProfitFirst() public {
        A.simulateGain(4_000e6);
        vault.report(A);
        B.simulateLoss(3_000e6);
        vault.report(B);
        // 4k ganados (bloqueados) − 3k perdidos: el totalAssets visible no cae
        assertEq(vault.totalAssets(), 100_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(vault.totalAssets(), 101_000e6);
    }

    /// @notice Sandwich del report: entrar antes y salir después no da ganancia.
    function test_SandwichReportUnprofitable() public {
        A.simulateGain(10_000e6);
        vm.prank(attacker);
        uint256 sh = vault.deposit(500_000e6, attacker);
        vault.report(A);
        vm.prank(attacker);
        uint256 out = vault.redeem(sh, attacker, attacker);
        assertLe(out, 500_000e6);
    }

    function test_WithdrawFollowsQueue() public {
        vm.prank(alice);
        vault.withdraw(60_000e6, alice, alice);
        assertEq(vault.idle(), 0);
        assertEq(_debt(A), 0, "primero A");
        assertEq(_debt(B), 40_000e6, "despues B");
        assertEq(vault.totalAssets(), 40_000e6);
    }

    function test_IlliquidStrategySkipsToNext() public {
        A.setLiquidityCap(10_000e6);
        vm.prank(alice);
        vault.withdraw(60_000e6, alice, alice);
        assertEq(_debt(A), 40_000e6);
        assertEq(_debt(B), 0);
    }

    function test_RevertsIfNotEnoughLiquidity() public {
        A.setLiquidityCap(0);
        B.setLiquidityCap(0);
        uint256 need = 6_000e6;
        uint256 got = 5_000e6;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MultiStrategyVault.InsufficientLiquidity.selector, need, got));
        vault.withdraw(need, alice, alice);
    }

    function test_CustomWithdrawQueue() public {
        IStrategy[] memory q = new IStrategy[](3);
        q[0] = B;
        q[1] = A;
        q[2] = C;
        vault.setWithdrawQueue(q);
        vm.prank(alice);
        vault.withdraw(20_000e6, alice, alice);
        assertEq(_debt(B), 30_000e6, "ahora B sale primero");
        assertEq(_debt(A), 50_000e6);
        q[2] = A; // duplicado
        vm.expectRevert(MultiStrategyVault.BadParam.selector);
        vault.setWithdrawQueue(q);
    }

    function test_RevokeStrategy() public {
        A.simulateGain(1_000e6);
        vault.revokeStrategy(A);
        assertEq(vault.idle(), 56_000e6);
        assertEq(_debt(A), 0);
        assertEq(address(vault.withdrawQueue(0)), address(B));
        vm.expectRevert(MultiStrategyVault.BadStrategy.selector);
        vault.report(A);
    }

    function test_AddStrategyValidation() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        MockStrategy bad = new MockStrategy(address(other), address(vault), 1);
        vm.expectRevert(MultiStrategyVault.BadStrategy.selector);
        vault.addStrategy(bad, 1_000);
        vm.expectRevert(MultiStrategyVault.BadStrategy.selector);
        vault.addStrategy(A, 1_000); // ya existe
    }

    function test_AccessControl() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.allocate();
        vm.expectRevert();
        vault.report(A);
        vm.expectRevert();
        vault.setParams(0, 0, alice);
        vm.stopPrank();
        vm.expectRevert(MultiStrategyVault.BadParam.selector);
        vault.setParams(500, 3_001, treasury);
    }

    function test_OnlyVaultCanMoveStrategyFunds() public {
        vm.prank(attacker);
        vm.expectRevert(MockStrategy.OnlyVault.selector);
        A.divest(1);
    }

    /// @notice Fuzz: depositar y retirar todo (forzando des-inversión) nunca devuelve de más.
    function testFuzz_RoundTrip(uint256 amt) public {
        amt = bound(amt, 1e6, 1_000_000e6);
        vm.startPrank(attacker);
        uint256 sh = vault.deposit(amt, attacker);
        vm.stopPrank();
        vault.allocate();
        vm.prank(attacker);
        uint256 out = vault.redeem(sh, attacker, attacker);
        assertLe(out, amt);
        assertApproxEqAbs(out, amt, 1);
    }
}
