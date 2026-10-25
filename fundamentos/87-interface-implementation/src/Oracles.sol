// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @title ManualOracle — implementación 1: precios cargados por un admin
/// @notice `is IPriceOracle` obliga al compilador a verificar que
///         implementemos todas las funciones de la interfaz.
contract ManualOracle is IPriceOracle {
    error NotAdmin();
    error UnknownAsset(bytes32 asset);

    address public immutable admin = msg.sender;
    mapping(bytes32 => uint256) private _prices;

    function setPrice(bytes32 asset, uint256 price) external {
        if (msg.sender != admin) revert NotAdmin();
        _prices[asset] = price;
        emit PriceUpdated(asset, price);
    }

    /// @inheritdoc IPriceOracle
    function getPrice(bytes32 asset) external view override returns (uint256 p) {
        p = _prices[asset];
        if (p == 0) revert UnknownAsset(asset);
    }

    /// @inheritdoc IPriceOracle
    function decimals() external pure override returns (uint8) {
        return 8;
    }
}

/// @title FixedOracle — implementación 2: precio constante (útil en tests)
contract FixedOracle is IPriceOracle {
    uint256 public immutable price;

    constructor(uint256 price_) {
        price = price_;
    }

    /// @inheritdoc IPriceOracle
    function getPrice(bytes32) external view override returns (uint256) {
        return price;
    }

    /// @inheritdoc IPriceOracle
    function decimals() external pure override returns (uint8) {
        return 8;
    }
}
