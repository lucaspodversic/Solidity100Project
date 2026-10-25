// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title JumpRateModel — modelo de tasa de interés con "quiebre" (kink)
/// @notice La tasa de préstamo depende de la utilización U = deuda / (deuda + liquidez):
///
///         U ≤ U*:  r = base + slope1 · U / U*
///         U > U*:  r = base + slope1 + slope2 · (U − U*) / (1 − U*)
///
///         Por encima de U* (ej. 80 %) la tasa sube abruptamente para atraer depósitos y
///         forzar repagos, asegurando que siempre haya liquidez para retiros.
/// @dev Tasas anuales en WAD (1e18 = 100 %). `borrowRatePerSecond` devuelve RAY (1e27).
contract JumpRateModel {
    uint256 internal constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public immutable baseRate;
    uint256 public immutable slope1;
    uint256 public immutable slope2;
    uint256 public immutable optimalUtilization;

    constructor(uint256 _base, uint256 _slope1, uint256 _slope2, uint256 _optimal) {
        require(_optimal > 0 && _optimal < WAD, "kink");
        baseRate = _base;
        slope1 = _slope1;
        slope2 = _slope2;
        optimalUtilization = _optimal;
    }

    /// @notice Utilización (WAD) dada la liquidez disponible y la deuda total.
    function utilization(uint256 cash, uint256 debt) public pure returns (uint256) {
        if (debt == 0) return 0;
        return (debt * WAD) / (cash + debt);
    }

    /// @notice Tasa anual de préstamo (WAD) para una utilización.
    function borrowRate(uint256 u) public view returns (uint256) {
        if (u <= optimalUtilization) return baseRate + (slope1 * u) / optimalUtilization;
        return baseRate + slope1 + (slope2 * (u - optimalUtilization)) / (WAD - optimalUtilization);
    }

    /// @notice Tasa anual de depósito: r_borrow · U · (1 − reserveFactor).
    function supplyRate(uint256 u, uint256 reserveFactor) external view returns (uint256) {
        return (((borrowRate(u) * u) / WAD) * (WAD - reserveFactor)) / WAD;
    }

    /// @notice Tasa por segundo en RAY (1e27) para acumular intereses.
    function borrowRatePerSecond(uint256 u) external view returns (uint256) {
        return (borrowRate(u) * 1e9) / SECONDS_PER_YEAR;
    }
}
