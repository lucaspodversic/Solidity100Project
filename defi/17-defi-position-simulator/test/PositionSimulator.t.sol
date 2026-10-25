// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionSimulator} from "../src/PositionSimulator.sol";

/// @title Tests del simulador de posiciones
/// @notice Posición base: 10 ETH a 2000 USD, deuda 12 000 USD, umbral 82,5 %, bonus 5 %,
///         close factor 50 %. HF inicial = 20 000·0,825/12 000 = 1,375.
contract PositionSimulatorTest is Test {
    PositionSimulator sim;

    function setUp() public {
        sim = new PositionSimulator();
    }

    function _base() internal pure returns (PositionSimulator.Params memory p) {
        p = PositionSimulator.Params({
            collateral: 10e18,
            debt: 12_000e18,
            price: 2000e18,
            liqThreshold: 0.825e18,
            liqBonus: 0.05e18,
            closeFactor: 0.5e18,
            borrowApr: 0,
            supplyApr: 0,
            stepSeconds: 1 days
        });
    }

    function _moves1(int256 a) internal pure returns (int256[] memory m) {
        m = new int256[](1);
        m[0] = a;
    }

    function test_LiquidationPrice() public view {
        uint256 lp = sim.liquidationPrice(10e18, 12_000e18, 0.825e18);
        assertApproxEqAbs(lp, 1454.545454545454545455e18, 1);
        // a ese precio, HF ≈ 1
        assertApproxEqAbs(sim.healthFactor(10e18, lp, 12_000e18, 0.825e18), 1e18, 1);
    }

    /// @notice −20 % no liquida (HF 1,1); el siguiente −15 % sí (HF 0,935 → liquidación parcial).
    function test_CrashSequenceTriggersPartialLiquidation() public view {
        int256[] memory m = new int256[](2);
        m[0] = -2000;
        m[1] = -1500;
        PositionSimulator.Snapshot[] memory s = sim.simulate(_base(), m);
        assertFalse(s[0].liquidated);
        assertEq(s[0].price, 1600e18);
        assertEq(s[0].healthFactor, 1.1e18);
        assertTrue(s[1].liquidated);
        assertEq(s[1].price, 1360e18);
        assertEq(s[1].debt, 6_000e18, "se repago el 50 %");
        // seize = 6000·1,05/1360 = 4,6323529… ETH
        assertApproxEqAbs(s[1].seized, 4.632352941176470588e18, 1);
        assertGt(s[1].healthFactor, 1e18, "la liquidacion sano la posicion");
    }

    /// @notice Crash de −70 % (colateral 6000 USD < deuda 12 000): el colateral no alcanza → queda deuda incobrable (equity < 0).
    function test_BadDebt() public view {
        PositionSimulator.Snapshot[] memory s = sim.simulate(_base(), _moves1(-7000));
        assertTrue(s[0].liquidated);
        assertEq(s[0].collateral, 0, "se confisco todo");
        assertGt(s[0].debt, 0);
        assertLt(s[0].equity, 0, "deuda incobrable para el protocolo");
    }

    function test_InterestAccrual() public view {
        PositionSimulator.Params memory p = _base();
        p.debt = 10_000e18;
        p.borrowApr = 0.1e18;
        p.supplyApr = 0.02e18;
        p.stepSeconds = 365 days;
        PositionSimulator.Snapshot[] memory s = sim.simulate(p, _moves1(0));
        assertEq(s[0].debt, 11_000e18);
        assertEq(s[0].collateral, 10.2e18);
    }

    /// @notice Interés compuesto entre pasos: 12 pasos mensuales al 12 % > 12 % simple.
    function test_CompoundingAcrossSteps() public view {
        PositionSimulator.Params memory p = _base();
        p.debt = 10_000e18;
        p.borrowApr = 0.12e18;
        p.stepSeconds = 365 days / 12;
        int256[] memory m = new int256[](12);
        PositionSimulator.Snapshot[] memory s = sim.simulate(p, m);
        assertApproxEqRel(s[11].debt, 11_268.25e18, 1e14); // (1,01)^12 ≈ 1,126825
    }

    function test_LeverageLoopConvergesTo1OverOneMinusLtv() public view {
        (uint256 c, uint256 d, uint256 lev) = sim.leverageLoop(1e18, 0.75e18, 60);
        assertApproxEqRel(lev, 4e18, 1e12);
        assertApproxEqRel(c - d, 1e18, 1e12, "equity se conserva");
        (,, uint256 lev1) = sim.leverageLoop(1e18, 0.75e18, 1);
        assertEq(lev1, 1.75e18);
    }

    function test_NetApr() public view {
        // 4x: col 4, deuda 3, supply 5 %, borrow 3 % → (0,20 − 0,09)/1 = 11 %
        assertEq(sim.netApr(4e18, 3e18, 0.05e18, 0.03e18), 0.11e18);
        // carry negativo: borrow 8 % → (0,20 − 0,24) = −4 %
        assertEq(sim.netApr(4e18, 3e18, 0.05e18, 0.08e18), -0.04e18);
    }

    function test_ImpermanentLoss() public view {
        assertEq(sim.lpValueRatio(1e18), 1e18, "sin cambio de precio no hay IL");
        assertEq(sim.lpValueRatio(4e18), 0.8e18, "x4 => IL 20 %");
        assertApproxEqAbs(sim.lpValueRatio(2e18), 0.942809041582063365e18, 1e3, "x2 => IL 5,72 %");
        assertEq(sim.lpValueRatio(0.25e18), 0.8e18, "simetria: /4 = x4");
    }

    function test_BadParamsRevert() public {
        PositionSimulator.Params memory p = _base();
        p.liqThreshold = 1e18;
        vm.expectRevert(PositionSimulator.BadParams.selector);
        sim.simulate(p, _moves1(0));
    }

    /// @notice Fuzz: si el colateral vale más que deuda·(1+bonus), una liquidación parcial
    ///         siempre MEJORA el HF (condición de diseño de los protocolos de lending).
    function testFuzz_LiquidationImprovesHfWhenSolvent(int256 move) public view {
        move = bound(move, -4000, -1300); // rango que liquida sin dejar insolvente
        PositionSimulator.Params memory p = _base();
        PositionSimulator.Snapshot[] memory s = sim.simulate(p, _moves1(move));
        uint256 price = s[0].price;
        uint256 hfBefore = sim.healthFactor(p.collateral, price, p.debt, p.liqThreshold);
        if (s[0].liquidated && p.collateral * price / 1e18 > p.debt * 105 / 100) {
            assertGt(s[0].healthFactor, hfBefore);
        }
    }

    /// @notice Fuzz: el loop nunca supera 1/(1−ltv) y conserva el equity.
    function testFuzz_LeverageBound(uint256 ltv, uint256 loops) public view {
        ltv = bound(ltv, 0.01e18, 0.95e18);
        loops = bound(loops, 0, 40);
        (uint256 c, uint256 d, uint256 lev) = sim.leverageLoop(100e18, ltv, loops);
        assertLe(lev, (1e36) / (1e18 - ltv) + 1);
        assertApproxEqAbs(c - d, 100e18, 100);
    }
}
