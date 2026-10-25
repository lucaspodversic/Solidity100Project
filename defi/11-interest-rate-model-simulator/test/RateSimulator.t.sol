// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IInterestRateModel} from "../src/IInterestRateModel.sol";
import {LinearModel} from "../src/models/LinearModel.sol";
import {KinkModel} from "../src/models/KinkModel.sol";
import {AdaptiveCurveModel} from "../src/models/AdaptiveCurveModel.sol";
import {RateSimulator} from "../src/RateSimulator.sol";

/// @title Tests del simulador de modelos de tasa
contract RateSimulatorTest is Test {
    LinearModel lin;
    KinkModel kink;
    AdaptiveCurveModel ada;
    RateSimulator sim;

    function setUp() public {
        lin = new LinearModel(0.02e18, 0.2e18); // 2 % + 20 %·U
        kink = new KinkModel(0, 0.04e18, 0.75e18, 0.8e18); // estilo Aave USDC
        ada = new AdaptiveCurveModel(0.9e18, 0.04e18, 50e18);
        sim = new RateSimulator();
    }

    function _steps(uint256 u, uint256 n, uint256 dt) internal pure returns (RateSimulator.Step[] memory s) {
        s = new RateSimulator.Step[](n);
        for (uint256 i; i < n; i++) s[i] = RateSimulator.Step(u, dt);
    }

    function test_LinearCurve() public view {
        assertEq(lin.borrowRate(0), 0.02e18);
        assertEq(lin.borrowRate(0.5e18), 0.12e18);
        assertEq(lin.borrowRate(1e18), 0.22e18);
    }

    function test_KinkCurve() public view {
        assertEq(kink.borrowRate(0.4e18), 0.02e18);
        assertEq(kink.borrowRate(0.8e18), 0.04e18);
        assertEq(kink.borrowRate(0.9e18), 0.04e18 + 0.375e18);
        assertEq(kink.borrowRate(1e18), 0.79e18);
    }

    function test_AdaptiveCurveShape() public view {
        assertEq(ada.borrowRate(0.9e18), 0.04e18); // en el objetivo
        assertEq(ada.borrowRate(1e18), 0.16e18); // 4×
        assertEq(ada.borrowRate(0), 0.01e18); // 1/4×
    }

    function test_AdaptiveRisesAboveTarget() public {
        uint256 r0 = ada.rateAtTarget();
        for (uint256 i; i < 7; i++) ada.update(1e18, 1 days); // U=100 % una semana
        assertGt(ada.rateAtTarget(), r0 * 2, "deberia mas que duplicarse");
    }

    function test_AdaptiveFallsBelowTarget() public {
        uint256 r0 = ada.rateAtTarget();
        for (uint256 i; i < 30; i++) ada.update(0.45e18, 1 days); // err = -0,5 durante 30 dias
        assertLt(ada.rateAtTarget(), r0 / 2);
    }

    function test_AdaptiveBounded() public {
        for (uint256 i; i < 400; i++) ada.update(0, 1 days);
        assertEq(ada.rateAtTarget(), ada.MIN_RATE_AT_TARGET());
        for (uint256 i; i < 400; i++) ada.update(1e18, 1 days);
        assertEq(ada.rateAtTarget(), ada.MAX_RATE_AT_TARGET());
    }

    function test_SimulateConstantMatchesCompounding() public {
        // Lineal a U=50 % → 12 % APR, pasos diarios por un año ≈ e^0,12 − 1 = 12,75 %
        RateSimulator.Result memory r = sim.simulate(lin, _steps(0.5e18, 365, 1 days), 1_000_000e18, 0);
        assertApproxEqRel(r.debtInterest, 127_474e18, 0.001e18);
        assertEq(r.avgBorrowApr, 0.12e18);
        // Sin reserve factor: supply = borrow·U = 6 % → ≈ 6,18 %
        assertApproxEqRel(r.supplyInterest, 61_831e18, 0.001e18);
    }

    function test_ReserveFactorReducesSupply() public {
        RateSimulator.Result memory a = sim.simulate(kink, _steps(0.7e18, 30, 1 days), 1e18, 0);
        RateSimulator.Result memory b = sim.simulate(kink, _steps(0.7e18, 30, 1 days), 1e18, 0.1e18);
        assertLt(b.supplyInterest, a.supplyInterest);
        assertEq(a.debtInterest, b.debtInterest);
    }

    function test_CompareStressScenario() public {
        // Corrida: U de 90 % a 100 % en 30 días (siempre en/sobre el objetivo del adaptativo)
        RateSimulator.Step[] memory s = sim.rampScenario(0.9e18, 1e18, 30, 1 days);
        IInterestRateModel[] memory ms = new IInterestRateModel[](3);
        ms[0] = lin;
        ms[1] = kink;
        ms[2] = ada;
        RateSimulator.Result[] memory res = sim.compare(ms, s, 1e18, 0);
        // El kink reacciona mucho más fuerte que el lineal en estrés
        assertGt(res[1].maxBorrowApr, res[0].maxBorrowApr * 3);
        // El adaptativo subió su rateAtTarget durante el estrés
        assertGt(ada.rateAtTarget(), 0.04e18);
    }

    function test_EmptyScenarioReverts() public {
        RateSimulator.Step[] memory s;
        vm.expectRevert(RateSimulator.EmptyScenario.selector);
        sim.simulate(lin, s, 1, 0);
    }

    /// @notice Fuzz: los modelos sin estado son monótonos crecientes en U.
    function testFuzz_Monotonic(uint256 a, uint256 b) public view {
        a = bound(a, 0, 1e18);
        b = bound(b, a, 1e18);
        assertLe(kink.borrowRate(a), kink.borrowRate(b));
        assertLe(lin.borrowRate(a), lin.borrowRate(b));
        assertLe(ada.borrowRate(a), ada.borrowRate(b));
    }

    /// @notice Fuzz: la tasa de depósito nunca supera la de préstamo.
    function testFuzz_SupplyLeBorrow(uint256 u, uint256 rf) public view {
        u = bound(u, 0, 1e18);
        rf = bound(rf, 0, 1e18);
        uint256 br = kink.borrowRate(u);
        assertLe(sim.supplyRate(br, u, rf), br);
    }
}
