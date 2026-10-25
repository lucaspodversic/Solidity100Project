// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IInterestRateModel} from "../IInterestRateModel.sol";

/// @title AdaptiveCurveModel — modelo adaptativo (inspirado en Morpho AdaptiveCurveIrm)
/// @notice Dos componentes:
///         1. Una CURVA fija alrededor de una utilización objetivo U* (ej. 90 %): en U* la tasa
///            es `rateAtTarget`; en U=1 es 4× y en U=0 es 1/4×. Reacciona al instante.
///         2. `rateAtTarget` se ADAPTA en el tiempo: si U se mantiene por encima de U*, sube
///            (exponencialmente, aproximado); si se mantiene por debajo, baja. Así el mercado
///            "descubre" la tasa de equilibrio sin gobernanza.
/// @dev err = (U − U*)/(1 − U*) si U > U*, o (U − U*)/U* si U ≤ U*; err ∈ [−1, 1].
///      rateAtTarget ← rateAtTarget · (1 + speed·err·dt), acotado a [MIN, MAX].
///      Usamos la aproximación lineal por intervalo; con updates frecuentes tiende a exp().
contract AdaptiveCurveModel is IInterestRateModel {
    int256 internal constant WAD = 1e18;
    /// @notice Pendiente de la curva (k = 4).
    int256 public constant CURVE_STEEPNESS = 4e18;
    uint256 public constant MIN_RATE_AT_TARGET = 0.001e18; // 0,1 %
    uint256 public constant MAX_RATE_AT_TARGET = 2e18; // 200 %

    uint256 public immutable targetUtilization;
    /// @notice Velocidad de ajuste por segundo (WAD). 50/año ⇒ con err=1 la tasa se duplica en ~1 semana.
    uint256 public immutable adjustmentSpeed;
    uint256 public rateAtTarget;

    event RateAtTargetUpdated(uint256 newRate);

    constructor(uint256 _target, uint256 _initialRateAtTarget, uint256 _speedPerYear) {
        require(_target > 0 && _target < 1e18, "target");
        targetUtilization = _target;
        rateAtTarget = _initialRateAtTarget;
        adjustmentSpeed = _speedPerYear / 365 days;
    }

    /// @notice Error normalizado de utilización, en [−1, 1] (WAD).
    function error_(uint256 u) public view returns (int256) {
        int256 t = int256(targetUtilization);
        int256 iu = int256(u > 1e18 ? 1e18 : u);
        if (iu > t) return ((iu - t) * WAD) / (WAD - t);
        return ((iu - t) * WAD) / t;
    }

    /// @notice Multiplicador de la curva: err<0 → (1 − 1/k)·err + 1 ; err≥0 → (k − 1)·err + 1.
    function _curve(int256 err) internal pure returns (int256) {
        int256 coeff = err < 0 ? WAD - (WAD * WAD) / CURVE_STEEPNESS : CURVE_STEEPNESS - WAD;
        return (coeff * err) / WAD + WAD;
    }

    function borrowRate(uint256 u) public view returns (uint256) {
        int256 m = _curve(error_(u));
        return (rateAtTarget * uint256(m)) / 1e18;
    }

    /// @notice Ajusta rateAtTarget según la utilización observada durante `dt` segundos.
    function update(uint256 u, uint256 dt) external {
        int256 err = error_(u);
        int256 delta = (int256(adjustmentSpeed) * err * int256(dt)) / WAD; // WAD
        // Acotamos el cambio por intervalo a [−50 %, +100 %] para estabilidad numérica
        if (delta < -0.5e18) delta = -0.5e18;
        if (delta > 1e18) delta = 1e18;
        int256 r = (int256(rateAtTarget) * (WAD + delta)) / WAD;
        uint256 nr = uint256(r);
        if (nr < MIN_RATE_AT_TARGET) nr = MIN_RATE_AT_TARGET;
        if (nr > MAX_RATE_AT_TARGET) nr = MAX_RATE_AT_TARGET;
        rateAtTarget = nr;
        emit RateAtTargetUpdated(nr);
    }

    function name() external pure returns (string memory) {
        return "AdaptiveCurve";
    }
}
