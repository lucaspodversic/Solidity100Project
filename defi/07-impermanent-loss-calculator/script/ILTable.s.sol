// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ILCalculator} from "../src/ILCalculator.sol";

/// @title ILTable — imprime una tabla de IL (rango completo vs. concentrado)
/// @notice Uso: `forge script script/ILTable.s.sol -vv` (no envía transacciones).
contract ILTable is Script {
    function run() external {
        ILCalculator calc = new ILCalculator();
        uint256 p0 = 2000e18;
        uint256[7] memory ps = [uint256(500e18), 1000e18, 1600e18, 2000e18, 2400e18, 4000e18, 8000e18];
        console.log("Precio inicial 2000. Rango concentrado [1600, 2500]");
        console.log("precio | IL full (bps) | IL rango (bps)");
        for (uint256 i; i < ps.length; i++) {
            uint256 full = calc.ilFullRange(p0, ps[i]);
            (uint256 rng,,) = calc.ilRange(p0, ps[i], 1600e18, 2500e18);
            console.log(ps[i] / 1e18, full / 1e14, rng / 1e14);
        }
    }
}
