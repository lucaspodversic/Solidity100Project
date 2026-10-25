// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueTracker} from "./RevenueTracker.sol";

/// @title MockToken — ERC20 de prueba con mint libre
contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @title MockDex — "DEX" mínimo que cobra 0,3% por swap y lo manda al tracker
/// @notice Simula una fuente real de comisiones. No hace swaps de verdad:
///         solo toma el token de entrada y descuenta la comisión.
contract MockDex {
    RevenueTracker public immutable tracker;
    uint256 public constant FEE_BPS = 30; // 0,30%

    constructor(RevenueTracker t) { tracker = t; }

    /// @notice "Swap": cobra la comisión y la reporta.
    function swap(IERC20 tokenIn, uint256 amountIn) external returns (uint256 fee) {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        fee = (amountIn * FEE_BPS) / 10_000;
        tokenIn.approve(address(tracker), fee);
        tracker.recordFee(address(tokenIn), fee);
    }
}

/// @title MockLending — fuente que paga comisiones en ETH
contract MockLending {
    RevenueTracker public immutable tracker;
    constructor(RevenueTracker t) { tracker = t; }

    /// @notice Simula cobrar interés en ETH y reportar el 10% como ingreso del protocolo.
    function repay() external payable {
        tracker.recordFeeETH{value: msg.value / 10}();
    }
}
