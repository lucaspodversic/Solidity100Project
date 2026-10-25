// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IInterestRateModel} from "../IInterestRateModel.sol";

/// @title KinkModel — modelo de dos pendientes (Compound v2 JumpRate / Aave v2)
/// @notice r(U) = base + s1·U/U*                        si U ≤ U*
///         r(U) = base + s1 + s2·(U − U*)/(1 − U*)      si U > U*
///         La segunda pendiente, mucho más empinada, defiende la liquidez.
contract KinkModel is IInterestRateModel {
    uint256 public immutable base;
    uint256 public immutable slope1;
    uint256 public immutable slope2;
    uint256 public immutable kink;

    constructor(uint256 _base, uint256 _s1, uint256 _s2, uint256 _kink) {
        require(_kink > 0 && _kink < 1e18, "kink");
        base = _base;
        slope1 = _s1;
        slope2 = _s2;
        kink = _kink;
    }

    function borrowRate(uint256 u) external view returns (uint256) {
        if (u <= kink) return base + (slope1 * u) / kink;
        return base + slope1 + (slope2 * (u - kink)) / (1e18 - kink);
    }

    function update(uint256, uint256) external {}

    function name() external pure returns (string memory) {
        return "Kink";
    }
}
