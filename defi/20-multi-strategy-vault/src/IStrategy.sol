// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStrategy — interfaz mínima que el vault espera de cada estrategia
/// @notice Cada estrategia invierte un único asset (el mismo del vault) en algún protocolo.
interface IStrategy {
    /// @notice Asset subyacente (debe coincidir con el del vault).
    function asset() external view returns (address);
    /// @notice Valor actual de lo invertido, medido en asset.
    function totalAssets() external view returns (uint256);
    /// @notice APY estimado en bps (lo reporta la estrategia; el vault lo usa para priorizar).
    function apyBps() external view returns (uint256);
    /// @notice El vault YA transfirió `amount`; la estrategia lo invierte.
    function invest(uint256 amount) external;
    /// @notice Devuelve hasta `amount` al vault. Retorna lo efectivamente enviado.
    function divest(uint256 amount) external returns (uint256);
}
