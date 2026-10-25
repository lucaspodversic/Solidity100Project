// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LendingPool} from "../protocol/LendingPool.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Cuenta auxiliar del script (deudora o depositante). Los scripts no deben usar
///         `address(this)`, así que las cuentas se modelan como contratos.
contract Borrower {
    function supply(LendingPool pool, MockERC20 token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.deposit(address(token), amount);
    }

    function open(LendingPool pool, MockERC20 weth, MockERC20 usdc, uint256 coll, uint256 debt) external {
        weth.approve(address(pool), coll);
        pool.deposit(address(weth), coll);
        pool.borrow(address(usdc), debt);
        usdc.transfer(msg.sender, debt);
    }
}
