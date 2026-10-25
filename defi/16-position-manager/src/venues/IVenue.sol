// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVenue — adaptador uniforme a un protocolo de rendimiento
/// @notice Cada venue envuelve UN protocolo (lending pool, vault ERC-4626, …) y custodia la
///         posición en nombre de un único `manager`. El manager sólo ve esta interfaz, así que
///         sumar un protocolo nuevo = escribir un venue nuevo, sin tocar el manager.
interface IVenue {
    /// @notice Activo subyacente (el mismo para todos los venues de un manager).
    function asset() external view returns (address);

    /// @notice Valor actual de la posición, en unidades del activo (incluye intereses).
    function totalAssets() external view returns (uint256);

    /// @notice Cuánto se puede retirar YA (puede ser < totalAssets si el protocolo está ilíquido).
    function maxWithdraw() external view returns (uint256);

    /// @notice Toma `amount` del manager (transferFrom) y lo deposita en el protocolo.
    function deposit(uint256 amount) external;

    /// @notice Retira `amount` del protocolo y lo envía al manager. Devuelve lo realmente recibido.
    function withdraw(uint256 amount) external returns (uint256 received);

    /// @notice Nombre legible para dashboards/eventos.
    function name() external view returns (string memory);
}
