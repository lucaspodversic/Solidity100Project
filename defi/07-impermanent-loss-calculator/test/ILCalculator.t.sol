// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ILCalculator} from "../src/ILCalculator.sol";
import {ILMath} from "../src/libraries/ILMath.sol";

/// @title Tests de la calculadora de pérdida impermanente
contract ILCalculatorTest is Test {
    ILCalculator calc;
    address user = makeAddr("user");

    function setUp() public {
        calc = new ILCalculator();
    }

    function test_NoPriceChangeNoIL() public view {
        assertEq(calc.ilFullRange(2000e18, 2000e18), 0);
    }

    function test_KnownValues() public view {
        // r = 4 -> 20 %
        assertApproxEqAbs(calc.ilFullRange(1e18, 4e18), 0.2e18, 1e9);
        // r = 0,25 -> 20 % (simetría)
        assertApproxEqAbs(calc.ilFullRange(4e18, 1e18), 0.2e18, 1e9);
        // r = 2 -> 1 - 2√2/3 = 5,719 %
        assertApproxEqRel(calc.ilFullRange(1e18, 2e18), 0.057190958e18, 1e12);
        // r = 1,25 -> 0,6 %
        assertApproxEqRel(calc.ilFullRange(1e18, 1.25e18), 0.006192010e18, 1e13);
    }

    function test_LpValueMatchesFormula() public pure {
        // 1 ETH + 2000 USDC a precio 2000; ETH sube a 8000 (r = 4)
        uint256 lp = ILMath.lpValueCP(1e18, 2000e18, 8000e18);
        uint256 hodl = ILMath.hodlValue(1e18, 2000e18, 8000e18);
        assertApproxEqRel(lp, 8000e18, 1e10); // 2√(2000·8000) = 8000
        assertEq(hodl, 10_000e18);
        assertApproxEqRel(1e18 - (lp * 1e18) / hodl, 0.2e18, 1e10);
    }

    function test_ConcentratedHasMoreIL() public view {
        // Rango [1600, 2500] alrededor de 2000; el precio sube a 2400 (dentro del rango)
        (uint256 ilRange,,) = calc.ilRange(2000e18, 2400e18, 1600e18, 2500e18);
        uint256 ilFull = calc.ilFullRange(2000e18, 2400e18);
        assertGt(ilRange, ilFull * 3, "la liquidez concentrada amplifica el IL");
    }

    function test_ConcentratedOutOfRangeAllInOneToken() public pure {
        (uint256 x, uint256 y) = ILMath.amountsPerLiquidity(3000e18, 1600e18, 2500e18);
        assertEq(x, 0); // por encima del rango: todo en Y (vendimos todo X)
        assertGt(y, 0);
        (x, y) = ILMath.amountsPerLiquidity(1000e18, 1600e18, 2500e18);
        assertEq(y, 0); // por debajo: todo en X
        assertGt(x, 0);
    }

    function test_WideRangeApproachesFullRange() public view {
        (uint256 il,,) = calc.ilRange(1e18, 2e18, 1e9, 1e27);
        assertApproxEqRel(il, calc.ilFullRange(1e18, 2e18), 0.01e18);
    }

    function test_BadRangeReverts() public {
        vm.expectRevert(ILMath.BadRange.selector);
        calc.ilRange(1e18, 2e18, 3e18, 2e18);
    }

    function test_RecordAndReport() public {
        vm.prank(user);
        uint256 id = calc.record(1e18, 2000e18, 2000e18, 0, 0);
        vm.warp(block.timestamp + 30 days);
        (uint256 il, uint256 lpV, uint256 hodl, uint256 apr) = calc.report(user, id, 8000e18);
        assertApproxEqRel(il, 0.2e18, 1e10);
        assertApproxEqRel(lpV, 8000e18, 1e10);
        assertEq(hodl, 10_000e18);
        // Faltan 2000 sobre 10000 en 30 días -> 20 % · 365/30 = 243 % APR
        assertApproxEqRel(apr, 2.4333e18, 0.001e18);
    }

    function test_RecordConcentratedReport() public {
        vm.prank(user);
        uint256 id = calc.record(1e18, 2000e18, 2000e18, 1600e18, 2500e18);
        (uint256 il, uint256 lpV, uint256 hodl,) = calc.report(user, id, 2000e18);
        assertEq(il, 0);
        assertApproxEqRel(lpV, hodl, 1e12);
        (il,,,) = calc.report(user, id, 2400e18);
        assertGt(il, 0);
    }

    function test_Scenarios() public view {
        uint256[] memory ps = new uint256[](3);
        ps[0] = 0.5e18;
        ps[1] = 1e18;
        ps[2] = 2e18;
        uint256[] memory ils = calc.scenarios(1e18, ps, 0, 0);
        assertEq(ils[1], 0);
        assertApproxEqAbs(ils[0], ils[2], 1e9); // simetría r y 1/r
    }

    /// @notice Fuzz: en x·y=k la LP nunca vale más que HODL (desigualdad AM-GM).
    function testFuzz_LpNeverBeatsHodl(uint256 x0, uint256 p0, uint256 p1) public pure {
        x0 = bound(x0, 1e15, 1e24);
        p0 = bound(p0, 1e12, 1e24);
        p1 = bound(p1, 1e12, 1e24);
        uint256 y0 = (x0 * p0) / 1e18; // entrada balanceada
        uint256 lp = ILMath.lpValueCP(x0, y0, p1);
        uint256 hodl = ILMath.hodlValue(x0, y0, p1);
        assertLe(lp, hodl + hodl / 1e9 + 1e9);
    }

    /// @notice Fuzz: el IL es simétrico en r y 1/r, y siempre menor que 100 %.
    function testFuzz_Symmetry(uint256 k) public view {
        k = bound(k, 1e16, 1e20); // r entre 0,01 y 100
        uint256 a = calc.ilFullRange(1e18, k);
        uint256 b = calc.ilFullRange(k, 1e18);
        assertApproxEqAbs(a, b, 1e10);
        assertLt(a, 1e18);
    }
}
