// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LendingPool} from "../protocol/LendingPool.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Cuenta auxiliar para scripts (los scripts no deben usar `address(this)`).
contract Account_ {
    function deposit(LendingPool pool, MockERC20 t, uint256 amt) external {
        t.approve(address(pool), amt);
        pool.deposit(address(t), amt);
    }

    function borrow(LendingPool pool, MockERC20 t, uint256 amt) external {
        pool.borrow(address(t), amt);
    }
}
