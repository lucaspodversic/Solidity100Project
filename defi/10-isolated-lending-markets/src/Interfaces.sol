// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Oráculo por mercado: precio de 1 unidad mínima de colateral expresado en unidades
///         mínimas del token prestado, escalado por 1e36 (convención de Morpho Blue). Así se
///         absorben las diferencias de decimales sin más cálculos.
interface IOracle {
    function price() external view returns (uint256);
}

/// @notice Modelo de tasa: devuelve la tasa de préstamo POR SEGUNDO (WAD) para un mercado.
interface IIrm {
    function borrowRate(uint256 totalSupplyAssets, uint256 totalBorrowAssets) external view returns (uint256);
}
