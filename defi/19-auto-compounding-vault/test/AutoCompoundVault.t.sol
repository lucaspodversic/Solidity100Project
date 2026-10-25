// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutoCompoundVault} from "../src/AutoCompoundVault.sol";
import {StakingFarm} from "../src/mocks/StakingFarm.sol";
import {SimpleAMM} from "../src/mocks/SimpleAMM.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests del vault auto-compounding
/// @notice Granja: 100 000 RWD repartidos en 1 año. AMM RWD/STK 1:1 con 1M de cada lado.
///         Un "whale" stakea 100 000 STK directo en la granja (competencia por rewards).
contract AutoCompoundVaultTest is Test {
    MockERC20 stk;
    MockERC20 rwd;
    StakingFarm farm;
    SimpleAMM amm;
    AutoCompoundVault vault;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address whale = makeAddr("whale");
    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");

    function setUp() public {
        stk = new MockERC20("Stake", "STK", 18);
        rwd = new MockERC20("Reward", "RWD", 18);
        farm = new StakingFarm(IERC20(address(stk)), IERC20(address(rwd)));
        amm = new SimpleAMM(IERC20(address(rwd)), IERC20(address(stk)));
        rwd.mint(address(this), 1_100_000e18);
        stk.mint(address(this), 1_000_000e18);
        rwd.approve(address(amm), type(uint256).max);
        stk.approve(address(amm), type(uint256).max);
        amm.seed(1_000_000e18, 1_000_000e18);
        rwd.approve(address(farm), type(uint256).max);
        farm.notifyReward(100_000e18, 365 days);
        vault = new AutoCompoundVault(IERC20(address(stk)), farm, amm, treasury);

        address[3] memory us = [alice, whale, attacker];
        for (uint256 i; i < 3; i++) {
            stk.mint(us[i], 2_000_000e18);
            vm.startPrank(us[i]);
            stk.approve(address(vault), type(uint256).max);
            stk.approve(address(farm), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(alice);
        vault.deposit(100_000e18, alice);
        vm.prank(whale);
        farm.stake(100_000e18);
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _harvest() internal returns (uint256 p) {
        vm.prank(keeper);
        p = vault.harvest(0);
    }

    function test_DepositIsStaked() public view {
        assertEq(farm.balanceOf(address(vault)), 100_000e18);
        assertEq(vault.totalAssets(), 100_000e18);
    }

    function test_HarvestCompoundsAndPaysBounty() public {
        _warp(30 days);
        (uint256 r, uint256 est) = vault.pendingHarvest();
        assertApproxEqRel(r, 4_109.589e18, 1e14, "mitad de 100k*30/365");
        uint256 p = _harvest();
        assertApproxEqRel(p, (est * 8_950) / 10_000, 1e12, "neto de bounty 0,5 % y fee 10 %");
        assertApproxEqRel(stk.balanceOf(keeper), (est * 50) / 10_000, 1e12);
        assertApproxEqRel(stk.balanceOf(treasury), (est * 1_000) / 10_000, 1e12);
        _warp(6 hours);
        assertApproxEqAbs(vault.totalAssets(), 100_000e18 + p, 1);
        assertGt(vault.convertToAssets(vault.balanceOf(alice)), 103_000e18);
    }

    function test_ProfitUnlocksLinearly() public {
        _warp(30 days);
        uint256 p = _harvest();
        assertApproxEqAbs(vault.totalAssets(), 100_000e18, 1, "recien cosechado: todo bloqueado");
        _warp(3 hours);
        assertApproxEqAbs(vault.totalAssets(), 100_000e18 + p / 2, 1e6, "mitad liberada");
    }

    function test_SlippageProtection() public {
        _warp(30 days);
        (, uint256 est) = vault.pendingHarvest();
        vm.prank(keeper);
        vm.expectRevert();
        vault.harvest(est + 1);
    }

    function test_NothingToHarvest() public {
        // mismo bloque que el depósito: todavía no se devengó ningún reward
        vm.prank(keeper);
        vm.expectRevert(AutoCompoundVault.NothingToHarvest.selector);
        vault.harvest(0);
    }

    /// @notice Sandwich: depositar 1M justo antes del harvest y retirar justo después.
    ///         Con la ganancia bloqueada, el atacante recupera a lo sumo lo que puso.
    function test_SandwichHarvestUnprofitable() public {
        _warp(30 days);
        vm.prank(attacker);
        uint256 sh = vault.deposit(1_000_000e18, attacker);
        _harvest();
        vm.prank(attacker);
        uint256 out = vault.redeem(sh, attacker, attacker);
        assertLe(out, 1_000_000e18, "el atacante no captura la ganancia");
        // alice sigue recibiendo su parte completa una vez liberada
        _warp(6 hours);
        assertGt(vault.convertToAssets(vault.balanceOf(alice)), 103_000e18);
    }

    /// @notice Componer semanalmente le gana a stakear directo y vender al final.
    function test_CompoundingBeatsSimpleStaking() public {
        // "bob" stakea lo mismo que alice pero directo, sin componer
        address bob = makeAddr("bob");
        stk.mint(bob, 100_000e18);
        vm.startPrank(bob);
        stk.approve(address(farm), type(uint256).max);
        farm.stake(100_000e18);
        vm.stopPrank();
        for (uint256 i; i < 52; i++) {
            _warp(7 days);
            _harvest();
        }
        _warp(7 days);
        vm.prank(bob);
        uint256 r = farm.getReward();
        uint256 bobValue = 100_000e18 + amm.getAmountOut(address(rwd), r);
        uint256 aliceValue = vault.convertToAssets(vault.balanceOf(alice));
        emit log_named_decimal_uint("alice (compone)", aliceValue, 18);
        emit log_named_decimal_uint("bob   (simple) ", bobValue, 18);
        assertGt(aliceValue, bobValue, "aun pagando 10,5 % de fees, componer gana");
    }

    function test_FeeCaps() public {
        vm.expectRevert(AutoCompoundVault.BadFee.selector);
        vault.setFees(301, 0, treasury);
        vm.prank(alice);
        vm.expectRevert();
        vault.setFees(0, 0, alice);
    }

    function test_WithdrawUnstakes() public {
        vm.prank(alice);
        vault.withdraw(40_000e18, alice, alice);
        assertEq(farm.balanceOf(address(vault)), 60_000e18);
        assertEq(stk.balanceOf(alice), 2_000_000e18 - 60_000e18);
    }

    /// @notice Fuzz: entrar y salir en cualquier momento (incluso alrededor de un harvest) no da ganancia.
    function testFuzz_NoFreeMoney(uint256 amt, uint256 wait) public {
        amt = bound(amt, 1e18, 1_000_000e18);
        wait = bound(wait, 1 hours, 60 days);
        _warp(wait);
        vm.prank(attacker);
        uint256 sh = vault.deposit(amt, attacker);
        _harvest();
        vm.prank(attacker);
        uint256 out = vault.redeem(sh, attacker, attacker);
        assertLe(out, amt);
    }
}
