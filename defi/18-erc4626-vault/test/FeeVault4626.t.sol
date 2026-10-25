// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeVault4626} from "../src/FeeVault4626.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests del vault ERC-4626 con fees
contract FeeVault4626Test is Test {
    MockERC20 usdc;
    FeeVault4626 vault;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        vault = new FeeVault4626(IERC20(address(usdc)), "Vault USDC", "vUSDC", treasury);
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            usdc.mint(u, 1_000_000e6);
            vm.prank(u);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    function _dep(address u, uint256 a) internal returns (uint256 s) {
        vm.prank(u);
        s = vault.deposit(a, u);
    }

    function test_DecimalsAndFirstDeposit() public {
        assertEq(vault.decimals(), 12);
        uint256 s = _dep(alice, 1_000e6);
        assertEq(s, 1_000e12, "1 USDC = 1e6 shares (offset 6)");
        assertEq(vault.totalAssets(), 1_000e6);
    }

    /// @notice Los preview coinciden EXACTAMENTE con la ejecución (requisito del estándar).
    function test_PreviewsMatchExecution() public {
        _dep(alice, 1_000e6);
        usdc.mint(address(vault), 37e6); // rendimiento: precio por share ≠ 1
        uint256 p = vault.previewDeposit(500e6);
        assertEq(_dep(bob, 500e6), p);
        uint256 pm = vault.previewMint(123e12);
        vm.prank(bob);
        assertEq(vault.mint(123e12, bob), pm);
        uint256 pw = vault.previewWithdraw(100e6);
        vm.prank(bob);
        assertEq(vault.withdraw(100e6, bob, bob), pw);
        uint256 sh = vault.balanceOf(bob);
        uint256 pr = vault.previewRedeem(sh);
        vm.prank(bob);
        assertEq(vault.redeem(sh, bob, bob), pr);
    }

    /// @notice Redondeo: mint cuesta ≥ lo que da redeem; withdraw quema ≥ lo que da deposit.
    function test_RoundingFavorsVault() public {
        _dep(alice, 1_000e6);
        usdc.mint(address(vault), 333_333); // precio "feo"
        assertGe(vault.previewMint(1e12), vault.previewRedeem(1e12));
        assertGe(vault.previewWithdraw(1e6), vault.previewDeposit(1e6));
    }

    function test_ManagementFeeDilutesTwoPercentPerYear() public {
        vault.setParams(treasury, 200, 0, type(uint256).max);
        _dep(alice, 100_000e6);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vault.accrueFees();
        uint256 tv = vault.convertToAssets(vault.balanceOf(treasury));
        assertApproxEqRel(tv, 1_960.78e6, 1e15, "2/102 del vault (dilucion lineal)");
        // y el preview de alice ya lo reflejaba antes de cobrar (no hay "esquive")
    }

    function test_PreviewIncludesPendingFees() public {
        vault.setParams(treasury, 200, 0, type(uint256).max);
        _dep(alice, 100_000e6);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 before = vault.previewRedeem(vault.balanceOf(alice));
        vault.accrueFees();
        assertEq(vault.previewRedeem(vault.balanceOf(alice)), before);
    }

    function test_PerformanceFeeWithHighWaterMark() public {
        vault.setParams(treasury, 0, 2_000, type(uint256).max); // 20 % de la ganancia
        _dep(alice, 100_000e6);
        usdc.mint(address(vault), 10_000e6); // +10 %
        vault.accrueFees();
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(treasury)), 2_000e6, 2e6);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 108_000e6, 2e6);

        // Pérdida: no se cobra nada hasta recuperar el máximo previo
        vm.prank(address(vault));
        usdc.transfer(address(0xdead), 11_000e6);
        uint256 tBefore = vault.balanceOf(treasury);
        usdc.mint(address(vault), 5_000e6); // recupera parcialmente (sigue bajo el HWM)
        vault.accrueFees();
        assertEq(vault.balanceOf(treasury), tBefore, "sin fee bajo el HWM");
        usdc.mint(address(vault), 11_000e6); // ahora sí supera el HWM por ~5k
        vault.accrueFees();
        assertGt(vault.balanceOf(treasury), tBefore);
    }

    function test_DepositCapAndPause() public {
        vault.setParams(treasury, 0, 0, 1_500e6);
        _dep(alice, 1_000e6);
        assertEq(vault.maxDeposit(bob), 500e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FeeVault4626.ExceedsMax.selector, 600e6, 500e6));
        vault.deposit(600e6, bob);

        vault.setPaused(true);
        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(1e6, bob);
        // retirar en pausa sigue permitido
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    function test_WithdrawOnBehalfNeedsAllowance() public {
        _dep(alice, 1_000e6);
        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(100e6, bob, alice);
        uint256 need = vault.previewWithdraw(100e6);
        vm.prank(alice);
        vault.approve(bob, need);
        vm.prank(bob);
        vault.withdraw(100e6, bob, alice);
        assertEq(vault.allowance(alice, bob), 0);
    }

    /// @notice Ataque de inflación: el atacante deposita 1 wei y dona 10 000 USDC.
    ///         Con shares virtuales la víctima recibe shares y el atacante PIERDE plata.
    function test_InflationAttackUnprofitable() public {
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 10_001e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1, attacker);
        usdc.transfer(address(vault), 10_000e6);
        vm.stopPrank();
        uint256 s = _dep(alice, 1_000e6);
        assertGt(s, 0, "la victima recibe shares");
        uint256 sh = vault.balanceOf(attacker);
        vm.prank(attacker);
        uint256 out = vault.redeem(sh, attacker, attacker);
        assertLt(out, 10_000e6, "el atacante pierde");
    }

    function test_FeeCaps() public {
        vm.expectRevert(FeeVault4626.BadFee.selector);
        vault.setParams(treasury, 501, 0, 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.setParams(treasury, 0, 0, 0);
    }

    /// @notice Fuzz: depositar y redimir en el acto nunca da ganancia.
    function testFuzz_NoFreeMoney(uint256 a, uint256 donation) public {
        a = bound(a, 1, 500_000e6);
        donation = bound(donation, 0, 100_000e6);
        _dep(alice, 10_000e6);
        usdc.mint(address(vault), donation);
        uint256 s = _dep(bob, a);
        vm.prank(bob);
        uint256 back = vault.redeem(s, bob, bob);
        assertLe(back, a);
    }

    /// @notice Fuzz: comprar con `mint` las shares que daría `deposit(a)` cuesta ≤ a (y a lo sumo 1 wei menos).
    function testFuzz_MintDepositConsistency(uint256 a) public {
        a = bound(a, 1e6, 500_000e6);
        _dep(alice, 10_000e6);
        usdc.mint(address(vault), 1_234_567);
        uint256 shares = vault.previewDeposit(a);
        assertGe(vault.previewMint(shares), a - 1);
        assertLe(vault.previewMint(shares), a);
    }
}
