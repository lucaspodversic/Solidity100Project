// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PriceOracle — oráculo simple administrado (precios en USD con 18 decimales)
/// @notice En producción se reemplazaría por Chainlink + TWAP. Mantiene un timestamp por
///         precio para que el pool pueda rechazar precios viejos.
contract PriceOracle is Ownable {
    struct Price {
        uint256 value; // USD por 1 token entero, en WAD
        uint64 updatedAt;
    }

    mapping(address => Price) internal _prices;
    /// @notice Antigüedad máxima aceptada.
    uint256 public maxAge = 1 days;

    event PriceSet(address indexed asset, uint256 price);

    error StalePrice(address asset);
    error NoPrice(address asset);

    constructor() Ownable(msg.sender) {}

    function setPrice(address asset, uint256 price) external onlyOwner {
        _prices[asset] = Price(price, uint64(block.timestamp));
        emit PriceSet(asset, price);
    }

    function setMaxAge(uint256 a) external onlyOwner {
        maxAge = a;
    }

    /// @notice Precio validado (revierte si no existe o está viejo).
    function getPrice(address asset) external view returns (uint256) {
        Price memory p = _prices[asset];
        if (p.value == 0) revert NoPrice(asset);
        if (block.timestamp - p.updatedAt > maxAge) revert StalePrice(asset);
        return p.value;
    }
}
