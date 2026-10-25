// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VenueBase} from "./VenueBase.sol";
import {LendingPool} from "../protocol/LendingPool.sol";

/// @title LendingPoolVenue — posición de "supply" en el LendingPool del proyecto 09
/// @notice Sólo deposita (nunca pide prestado), así que la posición no puede liquidarse.
///         El rendimiento sale de los intereses que pagan los deudores del pool.
contract LendingPoolVenue is VenueBase {
    using SafeERC20 for IERC20;

    LendingPool public immutable pool;

    constructor(address _manager, IERC20 asset_, LendingPool _pool) VenueBase(_manager, asset_) {
        pool = _pool;
        asset_.forceApprove(address(_pool), type(uint256).max);
    }

    /// @notice Saldo de depósito (supplyIndex al último accrue; subestima levemente entre accrues).
    function totalAssets() public view returns (uint256) {
        return pool.supplyBalance(address(_asset), address(this));
    }

    /// @notice Limitado por el `cash` del pool: si la utilización es 100 % no se puede salir.
    function maxWithdraw() external view returns (uint256) {
        (,,,,,,,,,,,, uint256 cash) = pool.markets(address(_asset));
        return Math.min(totalAssets(), cash);
    }

    function deposit(uint256 amount) external onlyManager {
        _asset.safeTransferFrom(msg.sender, address(this), amount);
        pool.deposit(address(_asset), amount);
    }

    function withdraw(uint256 amount) external onlyManager returns (uint256 received) {
        pool.accrue(address(_asset)); // así `max` incluye los intereses al segundo
        uint256 bal = totalAssets();
        if (amount > bal) amount = bal; // tolera polvo de redondeo
        if (amount == 0) return 0;
        received = pool.withdraw(address(_asset), amount);
        _asset.safeTransfer(manager, received);
    }

    function name() external pure returns (string memory) {
        return "LendingPool supply";
    }
}
