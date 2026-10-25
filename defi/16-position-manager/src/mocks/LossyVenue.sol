// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VenueBase} from "../venues/VenueBase.sol";

/// @title LossyVenue — venue de prueba que cobra un "haircut" al retirar
/// @notice Simula un protocolo con fee de salida oculto o slippage. Sirve para probar
///         que el manager detecta pérdidas en el rebalanceo (maxLossBps).
contract LossyVenue is VenueBase {
    using SafeERC20 for IERC20;

    uint256 public held;
    uint256 public haircutBps;

    constructor(address _manager, IERC20 asset_) VenueBase(_manager, asset_) {}

    function setHaircut(uint256 bps) external {
        haircutBps = bps;
    }

    function totalAssets() external view returns (uint256) {
        return held;
    }

    function maxWithdraw() external view returns (uint256) {
        return held;
    }

    function deposit(uint256 amount) external onlyManager {
        _asset.safeTransferFrom(msg.sender, address(this), amount);
        held += amount;
    }

    function withdraw(uint256 amount) external onlyManager returns (uint256 received) {
        if (amount > held) amount = held;
        held -= amount;
        received = amount - (amount * haircutBps) / 10_000;
        _asset.safeTransfer(manager, received);
        _asset.safeTransfer(address(0xdead), amount - received);
    }

    function name() external pure returns (string memory) {
        return "Lossy";
    }
}
