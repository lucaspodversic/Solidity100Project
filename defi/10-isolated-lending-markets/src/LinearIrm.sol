// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IIrm} from "./Interfaces.sol";

/// @title LinearIrm — tasa = base + slope · utilización (anualizada, convertida a por segundo)
contract LinearIrm is IIrm {
    uint256 public immutable baseAprWad;
    uint256 public immutable slopeAprWad;

    constructor(uint256 _base, uint256 _slope) {
        baseAprWad = _base;
        slopeAprWad = _slope;
    }

    function borrowRate(uint256 supplyAssets, uint256 borrowAssets) external view returns (uint256) {
        uint256 u = supplyAssets == 0 ? 0 : (borrowAssets * 1e18) / supplyAssets;
        return (baseAprWad + (slopeAprWad * u) / 1e18) / 365 days;
    }
}
