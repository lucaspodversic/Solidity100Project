// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @title MockVRF — simula Chainlink VRF / Data Feed
/// @notice El "oracle" (dueño) empuja valores; los consumidores leen `latest`.
contract MockVRF {
    address public oracle;
    uint256 public latest;
    uint256 public round;
    event Fulfilled(uint256 round, uint256 value);
    constructor(address oracle_) { oracle = oracle_; }
    function fulfill(uint256 value) external {
        require(msg.sender == oracle, "solo oracle");
        latest = value;
        unchecked { ++round; }
        emit Fulfilled(round, value);
    }
}
