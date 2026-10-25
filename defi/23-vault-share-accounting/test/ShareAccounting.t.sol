// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NaiveVault} from "../src/NaiveVault.sol";
import {OffsetOnlyVault} from "../src/OffsetOnlyVault.sol";
import {SafeVault} from "../src/SafeVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Ataques de donación/inflación y de redondeo: éxito contra NaiveVault, fracaso contra las defensas
contract ShareAccountingTest is Test {
    MockERC20 usdc;
    NaiveVault naive;
    OffsetOnlyVault offset;
    SafeVault safe;
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address alice = makeAddr("alice");

    uint256 constant DONATION = 10_000e6;
    uint256 constant VICTIM_DEP = 10_000e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        naive = new NaiveVault(IERC20(address(usdc)));
        offset = new OffsetOnlyVault(IERC20(address(usdc)));
        safe = new SafeVault(IERC20(address(usdc)));
        address[3] memory us = [attacker, victim, alice];
        for (uint256 i; i < 3; i++) {
            usdc.mint(us[i], 1_000_000e6);
            vm.startPrank(us[i]);
            usdc.approve(address(naive), type(uint256).max);
            usdc.approve(address(offset), type(uint256).max);
            usdc.approve(address(safe), type(uint256).max);
            vm.stopPrank();
        }
    }

    // =================================================================
    // 1. Ataque de inflación (donación al primer depósito)
    // =================================================================

    /// @notice ❌ El atacante deposita 1 wei, dona 10 000 USDC y la víctima recibe 0 shares.
    function test_Naive_InflationAttackSucceeds() public {
        vm.startPrank(attacker);
        naive.deposit(1); // 1 share
        usdc.transfer(address(naive), DONATION); // donación: pps = 10 000 USDC por share
        vm.stopPrank();

        vm.prank(victim);
        uint256 shares = naive.deposit(VICTIM_DEP); // 10 000e6 · 1 / (10 000e6 + 1) = 0
        assertEq(shares, 0, "la victima no recibe nada");

        vm.prank(attacker);
        naive.redeem(1);
        uint256 profit = usdc.balanceOf(attacker) - (1_000_000e6 - 1 - DONATION) - DONATION - 1;
        assertEq(profit, VICTIM_DEP, "el atacante se queda con todo el deposito de la victima");
    }

    /// @notice ✅ Con shares virtuales la víctima recibe shares y el atacante PIERDE la donación.
    function test_Offset_InflationAttackUnprofitable() public {
        vm.startPrank(attacker);
        offset.deposit(1, attacker);
        usdc.transfer(address(offset), DONATION);
        vm.stopPrank();

        vm.prank(victim);
        uint256 shares = offset.deposit(VICTIM_DEP, victim);
        assertGt(shares, 0);

        uint256 atkShares = offset.balanceOf(attacker); // leer ANTES del prank
        vm.prank(attacker);
        offset.redeem(atkShares, attacker, attacker);
        uint256 attackerBal = usdc.balanceOf(attacker);
        // Con 1 wei el atacante tiene 1e6 shares y las shares virtuales otras 1e6: la mitad de la
        // donación queda "atrapada" del lado virtual/víctima. Pierde ≈ 50 % de lo donado.
        uint256 lost = 1_000_000e6 - attackerBal;
        assertGt(lost, (DONATION * 40) / 100, "pierde gran parte de la donacion");

        // la víctima pierde solo polvo de redondeo (< 0,0001 %), el atacante miles de USDC
        uint256 victimAssets = offset.previewRedeem(shares);
        assertApproxEqRel(victimAssets, VICTIM_DEP, 1e12);
    }

    /// @notice ✅ Con contabilidad interna la donación ni siquiera mueve el precio.
    function test_Safe_DonationIgnored() public {
        vm.startPrank(attacker);
        safe.deposit(1, attacker);
        usdc.transfer(address(safe), DONATION);
        vm.stopPrank();
        assertEq(safe.totalAssets(), 1, "la donacion no cuenta");
        assertEq(safe.excess(), DONATION);

        vm.prank(victim);
        uint256 shares = safe.deposit(VICTIM_DEP, victim);
        assertEq(shares, VICTIM_DEP * 1e6, "precio intacto: 1 USDC = 1e6 shares");
        assertEq(safe.previewRedeem(shares), VICTIM_DEP);

        // la donación queda para el tesoro (skim), no para el atacante
        address treasury = makeAddr("treasury");
        safe.skim(treasury);
        assertEq(usdc.balanceOf(treasury), DONATION);
    }

    function test_Safe_RejectsZeroShareDeposit() public {
        // con offset 6 un depósito de 1 wei da 1e6 shares; forzamos 0 con pps enorme via yield reconocido
        vm.prank(alice);
        safe.deposit(1, alice);
        usdc.mint(address(safe), 1e30);
        safe.reportYield(1e30); // pps astronómico
        vm.prank(victim);
        vm.expectRevert(bytes("0 shares"));
        safe.deposit(1, victim);
    }

    // =================================================================
    // 2. Ataque de redondeo (retiros de polvo que queman 0 shares)
    // =================================================================

    /// @notice ❌ Con pps > 1, `withdraw(1)` quema floor(1·supply/assets) = 0 shares: dinero gratis.
    function test_Naive_RoundingDrain() public {
        vm.prank(alice);
        naive.deposit(1_000e6);
        usdc.mint(address(naive), 1_000e6); // rendimiento legítimo: pps = 2
        uint256 before = usdc.balanceOf(attacker);
        vm.startPrank(attacker); // ¡el atacante no tiene shares!
        for (uint256 i; i < 50; i++) naive.withdraw(1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(attacker) - before, 50, "50 wei robados sin tener shares");
        assertEq(naive.balanceOf(attacker), 0);
    }

    /// @notice ✅ OZ redondea `previewWithdraw` hacia arriba: siempre quema ≥ 1 share.
    function test_Safe_RoundingDrainFails() public {
        vm.prank(alice);
        safe.deposit(1_000e6, alice);
        usdc.mint(address(safe), 1_000e6);
        safe.reportYield(1_000e6); // pps = 2
        assertGt(safe.previewWithdraw(1), 0);
        vm.prank(attacker);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw: no tiene shares
        safe.withdraw(1, attacker, attacker);
    }

    /// @notice ✅ Las cuatro direcciones redondean a favor del vault.
    function test_Safe_RoundingDirections() public {
        vm.prank(alice);
        safe.deposit(1_000e6, alice);
        usdc.mint(address(safe), 333e6 + 7);
        safe.reportYield(333e6 + 7); // pps "feo" para forzar restos
        uint256 a = 12_345;
        assertLe(safe.previewDeposit(a), safe.convertToShares(a)); // recibís ≤
        assertGe(safe.previewWithdraw(a), safe.convertToShares(a)); // quemás ≥
        uint256 s = 7_777_777;
        assertGe(safe.previewMint(s), safe.convertToAssets(s)); // pagás ≥
        assertLe(safe.previewRedeem(s), safe.convertToAssets(s)); // recibís ≤
    }

    // =================================================================
    // 3. Slippage
    // =================================================================

    function test_Safe_SlippageProtection() public {
        vm.prank(alice);
        safe.deposit(1_000e6, alice);
        uint256 expected = safe.previewDeposit(500e6);
        // entre la simulación y la ejecución el pps sube (p. ej. un reportYield)
        usdc.mint(address(safe), 1_000e6);
        safe.reportYield(1_000e6);
        vm.prank(victim);
        vm.expectRevert(SafeVault.SlippageExceeded.selector);
        safe.depositWithMin(500e6, victim, expected);
    }

    // =================================================================
    // 4. Fuzz
    // =================================================================

    /// @notice Naive: si la donación ≥ depósito de la víctima, la víctima recibe 0 shares.
    function testFuzz_Naive_AlwaysVulnerable(uint256 donation, uint256 dep) public {
        dep = bound(dep, 1, 500_000e6);
        donation = bound(donation, dep, 900_000e6);
        vm.startPrank(attacker);
        naive.deposit(1);
        usdc.transfer(address(naive), donation);
        vm.stopPrank();
        vm.prank(victim);
        assertEq(naive.deposit(dep), 0);
    }

    /// @notice Safe: para cualquier combinación, la víctima recupera su depósito y el atacante no gana.
    function testFuzz_Safe_VictimProtected(uint256 atk, uint256 donation, uint256 dep) public {
        atk = bound(atk, 1, 100_000e6);
        donation = bound(donation, 0, 500_000e6);
        dep = bound(dep, 1, 300_000e6);
        uint256 start = usdc.balanceOf(attacker);
        vm.startPrank(attacker);
        uint256 sa = safe.deposit(atk, attacker);
        usdc.transfer(address(safe), donation);
        vm.stopPrank();
        vm.prank(victim);
        uint256 sv = safe.deposit(dep, victim);
        assertEq(safe.previewRedeem(sv), dep, "la victima no pierde nada");
        vm.prank(attacker);
        safe.redeem(sa, attacker, attacker);
        assertLe(usdc.balanceOf(attacker), start, "el atacante nunca gana");
    }

    /// @notice Offset: el atacante nunca gana con donación (aunque no sea absoluto, es antieconómico).
    function testFuzz_Offset_AttackerNeverProfits(uint256 donation, uint256 dep) public {
        donation = bound(donation, 1, 500_000e6);
        dep = bound(dep, 1, 300_000e6);
        uint256 start = usdc.balanceOf(attacker);
        vm.startPrank(attacker);
        uint256 sa = offset.deposit(1, attacker);
        usdc.transfer(address(offset), donation);
        vm.stopPrank();
        vm.prank(victim);
        offset.deposit(dep, victim);
        vm.prank(attacker);
        offset.redeem(sa, attacker, attacker);
        assertLe(usdc.balanceOf(attacker), start);
    }
}
