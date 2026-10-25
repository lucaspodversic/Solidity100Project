// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceOracle — interfaz mínima de un oráculo de precios
/// @notice Una interfaz declara funciones `external` sin implementación.
///         Cualquier contrato que la implemente puede ser usado por los
///         consumidores sin que estos conozcan su código: **desacople**.
/// @dev Reglas de las interfaces en Solidity:
///   - no tienen constructor ni variables de estado;
///   - todas las funciones son `external` y no tienen cuerpo;
///   - pueden declarar eventos, errores, structs y enums;
///   - pueden heredar de otras interfaces.
interface IPriceOracle {
    /// @notice Se emite al actualizar un precio.
    event PriceUpdated(bytes32 indexed asset, uint256 price);

    /// @notice Precio del activo con 8 decimales (estilo Chainlink).
    function getPrice(bytes32 asset) external view returns (uint256);

    /// @notice Cantidad de decimales del precio.
    function decimals() external view returns (uint8);
}
