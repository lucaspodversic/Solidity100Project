// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {CurveStylePool, PriceVault, PoolSafe} from "../src/Pool.sol";
import {ROAttacker} from "../src/Attacker.sol";

contract ROTest is Test {
    CurveStylePool pool;
    PriceVault vault;
    PoolSafe safe;

    function setUp() public {
        pool = new CurveStylePool();
        vault = new PriceVault(address(pool));
        safe = new PoolSafe();
        pool.addLiquidity{value: 10 ether}();
        safe.addLiquidity{value: 10 ether}();
    }

    function test_PrecioInfladoDuranteReentrancy() public {
        uint256 priceAntes = pool.getVirtualPrice();
        PriceCatcher catcher = new PriceCatcher(address(pool));
        catcher.seed{value: 5 ether}();
        uint256 mid = catcher.attackAndCatch();
        assertTrue(mid >= priceAntes);
    }

    function test_SafeViewRevierteSiLocked() public {
        SafeCatcher c = new SafeCatcher(address(safe));
        c.seed{value: 5 ether}();
        c.attackAndCatch();
        assertTrue(c.viewReverted());
    }
}

contract PriceCatcher {
    CurveStylePool pool;
    uint256 public midPrice;
    constructor(address p) { pool = CurveStylePool(p); }
    function seed() external payable { pool.addLiquidity{value: msg.value}(); }
    function attackAndCatch() external returns (uint256) {
        pool.removeLiquidity(pool.lp(address(this)) / 2);
        return midPrice;
    }
    receive() external payable { midPrice = pool.getVirtualPrice(); }
}

contract SafeCatcher {
    PoolSafe pool;
    bool public viewReverted;
    constructor(address p) { pool = PoolSafe(p); }
    function seed() external payable { pool.addLiquidity{value: msg.value}(); }
    function attackAndCatch() external {
        pool.removeLiquidity(pool.lp(address(this)) / 2);
    }
    receive() external payable {
        // Capturamos que el view revierte por el lock, sin tumbar el transfer.
        try pool.getVirtualPrice() returns (uint256) {
            viewReverted = false;
        } catch {
            viewReverted = true;
        }
    }
}
