// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVenue} from "./IVenue.sol";

/// @title VenueBase — lógica común de permisos de los venues
/// @dev Fija el manager al construir: nadie más puede mover la posición. El manager es el
///      único "usuario" del protocolo subyacente a través de este contrato.
abstract contract VenueBase is IVenue {
    /// @notice Único contrato autorizado a depositar/retirar.
    address public immutable manager;
    /// @notice Activo subyacente.
    IERC20 internal immutable _asset;

    error OnlyManager();

    constructor(address _manager, IERC20 asset_) {
        manager = _manager;
        _asset = asset_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert OnlyManager();
        _;
    }

    /// @inheritdoc IVenue
    function asset() external view returns (address) {
        return address(_asset);
    }
}
