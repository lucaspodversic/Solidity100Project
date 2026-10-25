// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IInterestRateModel} from "../IInterestRateModel.sol";

/// @title LinearModel — r(U) = base + slope · U
/// @notice El modelo más simple (Compound v1). Problema: con U alto la tasa no sube lo
///         suficiente y el pool puede quedarse sin liquidez para retiros.
contract LinearModel is IInterestRateModel {
    uint256 public immutable base;
    uint256 public immutable slope;

    constructor(uint256 _base, uint256 _slope) {
        base = _base;
        slope = _slope;
    }

    function borrowRate(uint256 u) external view returns (uint256) {
        return base + (slope * u) / 1e18;
    }

    function update(uint256, uint256) external {}

    function name() external pure returns (string memory) {
        return "Lineal";
    }
}
