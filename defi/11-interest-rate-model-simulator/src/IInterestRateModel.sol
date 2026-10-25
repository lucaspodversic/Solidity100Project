// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IInterestRateModel — interfaz común de los modelos de tasa
/// @notice Todas las tasas son ANUALES en WAD (1e18 = 100 %). La utilización también es WAD.
interface IInterestRateModel {
    /// @notice Tasa de préstamo para una utilización dada (vista, sin cambiar estado).
    function borrowRate(uint256 utilization) external view returns (uint256);

    /// @notice Hook para modelos con estado (adaptativos). Los modelos sin estado no hacen nada.
    /// @param utilization Utilización observada durante el intervalo.
    /// @param dt Segundos transcurridos.
    function update(uint256 utilization, uint256 dt) external;

    /// @notice Nombre legible del modelo.
    function name() external view returns (string memory);
}
