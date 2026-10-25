// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "./IPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PriceConsumer — consume CUALQUIER oráculo vía interfaz
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #87
/// @notice Solo conoce `IPriceOracle`; el dueño puede cambiar de proveedor
///         (manual, fijo, Chainlink adaptado...) sin redeplegar este contrato.
/// @dev Además muestra cómo usar la interfaz estándar `IERC20` para leer el
///      saldo de cualquier token y valorizarlo en USD.
contract PriceConsumer {
    error NotOwner();
    error ZeroAddress();

    event OracleChanged(address indexed oldOracle, address indexed newOracle);

    address public immutable owner = msg.sender;
    /// @notice Oráculo actual, tipado como interfaz.
    IPriceOracle public oracle;

    constructor(IPriceOracle oracle_) {
        oracle = oracle_;
    }

    /// @notice Cambiar de implementación de oráculo.
    function setOracle(IPriceOracle newOracle) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(newOracle) == address(0)) revert ZeroAddress();
        emit OracleChanged(address(oracle), address(newOracle));
        oracle = newOracle;
    }

    /// @notice Valor en USD (8 dec.) de `amount` unidades (18 dec.) de `asset`.
    function valueOf(bytes32 asset, uint256 amount) public view returns (uint256) {
        // Llamada externa a través de la interfaz: el compilador arma el
        // calldata con el selector correcto y decodifica el retorno.
        return (oracle.getPrice(asset) * amount) / 1e18;
    }

    /// @notice Valoriza la tenencia de `holder` en el token `token`.
    function portfolioValue(IERC20 token, bytes32 asset, address holder) external view returns (uint256) {
        return valueOf(asset, token.balanceOf(holder));
    }
}
