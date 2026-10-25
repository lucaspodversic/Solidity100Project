// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SynthMinter} from "../src/SynthMinter.sol";
import {SyntheticAsset} from "../src/SyntheticAsset.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice sXAU (oro sintético a 2500 USD) respaldado por WETH (2000 USD).
contract SynthMinterTest is Test {
    MockERC20 weth;
    PriceOracle oracle;
    SynthMinter minter;
    SyntheticAsset sxau;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address liq = makeAddr("liquidator");

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        oracle = new PriceOracle();
        oracle.setMaxAge(3650 days);
        minter = new SynthMinter(weth, oracle, treasury, 1_000e18, "Synthetic Gold", "sXAU");
        sxau = minter.synth();
        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(sxau), 2500e18);

        _user(alice, 3e18);
        _user(liq, 100e18);
    }

    function _user(address u, uint256 amt) internal {
        weth.mint(u, amt);
        vm.startPrank(u);
        weth.approve(address(minter), type(uint256).max);
        minter.deposit(amt);
        vm.stopPrank();
    }

    function test_MintUpToMCR() public {
        // 3 WETH = 6000 USD → a 150 % puede deber 4000 USD = 1,6 sXAU
        assertEq(minter.maxMintable(alice), 1.6e18);
        vm.startPrank(alice);
        vm.expectPartialRevert(SynthMinter.BelowMCR.selector);
        minter.mint(1.6e18 + 1e12);
        minter.mint(1.6e18);
        vm.stopPrank();
        assertEq(sxau.balanceOf(alice), 1.6e18);
        assertEq(minter.collateralRatio(alice), 15_000);
        // liquidable si WETH < 2000·120/150 = 1600
        assertEq(minter.liquidationPrice(alice), 1600e18);
    }

    function test_WithdrawBlockedBelowMCR() public {
        vm.startPrank(alice);
        minter.mint(1e18); // CR 240 %
        vm.expectPartialRevert(SynthMinter.BelowMCR.selector);
        minter.withdraw(1.2e18); // dejaría 1,8 WETH = 3600 / 2500 = 144 %
        minter.withdraw(1e18); // 2 WETH = 4000/2500 = 160 % ok
        vm.stopPrank();
    }

    function test_SynthPriceRiseMakesVaultLiquidatable() public {
        vm.prank(alice);
        minter.mint(1.6e18);
        // el oro sube: la deuda vale más (riesgo propio de los sintéticos)
        oracle.setPrice(address(sxau), 3200e18); // CR = 6000/5120 = 117 %
        assertLt(minter.collateralRatio(alice), 12_000);
    }

    function test_Liquidation_PartialWithPenalty() public {
        vm.prank(alice);
        minter.mint(1.6e18);
        vm.prank(liq);
        minter.mint(10e18); // el liquidador acuña sXAU para repagar

        vm.expectRevert(abi.encodeWithSelector(SynthMinter.NotLiquidatable.selector, uint256(15_000)));
        vm.prank(liq);
        minter.liquidate(alice, 1e18);

        oracle.setPrice(address(weth), 1500e18); // CR = 4500/4000 = 112,5 %
        vm.prank(liq);
        uint256 seized = minter.liquidate(alice, 10e18); // se limita al 50 %
        // 0,8 sXAU = 2000 USD; +10 % = 2200 USD = 1,4667 WETH
        assertApproxEqAbs(seized, 1.466666666666666666e18, 1);
        assertEq(minter.debtOf(alice), 0.8e18);
        assertEq(weth.balanceOf(liq), seized);
        emit log_named_uint("CR tras liquidacion (bps)", minter.collateralRatio(alice));
    }

    function test_StabilityFeeAccruesToTreasury() public {
        vm.prank(alice);
        minter.mint(1e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertApproxEqAbs(minter.debtOf(alice), 1.05e18, 1);
        minter.accrue();
        assertApproxEqAbs(sxau.balanceOf(treasury), 0.05e18, 1);
        // la oferta de sXAU sigue igual a la deuda total (todo sAsset está respaldado)
        assertApproxEqAbs(sxau.totalSupply(), minter.totalDebt(), 2);

        // repagar todo requiere comprar el 5 % extra (acá se lo pasa el tesoro)
        vm.prank(treasury);
        sxau.transfer(alice, 0.05e18);
        vm.prank(alice);
        minter.burn(type(uint256).max);
        assertEq(minter.debtOf(alice), 0);
        (, uint256 nd) = minter.vaults(alice);
        assertEq(nd, 0);
    }

    function test_StabilityFeeChangeAccruesFirst() public {
        vm.prank(alice);
        minter.mint(1e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        minter.setStabilityFee(0.2e18); // sube al 20 %: el año pasado se cobra al 5 %
        assertApproxEqAbs(minter.debtOf(alice), 1.05e18, 1);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertApproxEqAbs(minter.debtOf(alice), 1.26e18, 1); // 1,05 · 1,2
    }

    function test_BadDebtAndHeal() public {
        vm.prank(alice);
        minter.mint(1.6e18);
        vm.prank(liq);
        minter.mint(10e18);
        oracle.setPrice(address(weth), 500e18); // 3 WETH = 1500 USD vs 4000 de deuda
        vm.prank(liq);
        uint256 seized = minter.liquidate(alice, type(uint256).max);
        assertEq(seized, 3e18); // todo el colateral
        (uint256 c, uint256 nd) = minter.vaults(alice);
        assertEq(c, 0);
        assertEq(nd, 0);
        // repagó 3·500/(2500·1,1) = 0,5454 sXAU; el resto (≈1,0545) es incobrable
        assertApproxEqAbs(minter.badDebt(), 1.6e18 - 0.545454545454545454e18, 2);

        // el tesoro (con fees o fondos propios) cancela parte de la deuda incobrable
        deal(address(sxau), treasury, 1e18);
        vm.prank(treasury);
        minter.healBadDebt(1e18);
        assertApproxEqAbs(minter.badDebt(), 0.054545454545454546e18, 2);
    }

    function test_DebtCeiling() public {
        minter.setDebtCeiling(1e18);
        vm.prank(alice);
        vm.expectRevert(SynthMinter.DebtCeilingExceeded.selector);
        minter.mint(1.1e18);
    }

    function test_OnlyMinterCanMintSynth() public {
        vm.expectRevert(SyntheticAsset.OnlyMinter.selector);
        sxau.mint(address(this), 1);
    }

    function test_RiskParamsValidated() public {
        vm.expectRevert(SynthMinter.ParamsInvalid.selector);
        minter.setRisk(12_000, 12_000, 500); // mcr debe ser > ratio de liquidación
        vm.expectRevert(SynthMinter.ParamsInvalid.selector);
        minter.setRisk(15_000, 12_000, 2_500); // penalidad ≥ colchón → liquidar crearía deuda incobrable
    }

    /// @notice Fuzz: acuñar dentro de maxMintable siempre deja CR ≥ MCR, y con el tiempo la
    ///         oferta de sXAU coincide con la deuda total.
    function testFuzz_MintAndAccrue(uint256 amt, uint32 dt) public {
        uint256 max_ = minter.maxMintable(alice);
        amt = bound(amt, 1e6, max_);
        vm.prank(alice);
        minter.mint(amt);
        assertGe(minter.collateralRatio(alice), 15_000);
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1, 3 * 365 days));
        minter.accrue();
        assertApproxEqAbs(sxau.totalSupply(), minter.totalDebt(), 3);
        assertGe(minter.debtOf(alice), amt);
    }
}
