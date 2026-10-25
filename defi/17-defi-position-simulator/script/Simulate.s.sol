// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PositionSimulator} from "../src/PositionSimulator.sol";

/// @title Simulate — compara 3 niveles de apalancamiento ante una semana de caídas
/// @notice `forge script script/Simulate.s.sol -vv`. Configurable con variables de entorno:
///         SIM_DROP_BPS (caída diaria, default 800 = −8 %) y SIM_DAYS (default 7).
contract Simulate is Script {
    function run() external {
        PositionSimulator sim = new PositionSimulator();
        uint256 drop = vm.envOr("SIM_DROP_BPS", uint256(800));
        uint256 daysN = vm.envOr("SIM_DAYS", uint256(7));
        int256[] memory moves = new int256[](daysN);
        for (uint256 i; i < daysN; i++) {
            moves[i] = -int256(drop);
        }
        uint256[3] memory ltvs = [uint256(0.3e18), 0.5e18, 0.7e18];
        for (uint256 k; k < 3; k++) {
            // 10 ETH de capital propio apalancados con un loop de 5 vueltas
            (uint256 col, uint256 debtEth,) = sim.leverageLoop(10e18, ltvs[k], 5);
            PositionSimulator.Params memory p = PositionSimulator.Params({
                collateral: col,
                debt: debtEth * 2000, // deuda en USD (pedimos USDC y compramos ETH a 2000)
                price: 2000e18,
                liqThreshold: 0.825e18,
                liqBonus: 0.05e18,
                closeFactor: 0.5e18,
                borrowApr: 0.05e18,
                supplyApr: 0.02e18,
                stepSeconds: 1 days
            });
            console.log("=== LTV objetivo (%):", ltvs[k] * 100 / 1e18);
            console.log("    colateral ETH x100:", col * 100 / 1e18, "liq. price USD:", sim.liquidationPrice(p.collateral, p.debt, p.liqThreshold) / 1e18);
            PositionSimulator.Snapshot[] memory s = sim.simulate(p, moves);
            for (uint256 i; i < s.length; i++) {
                string memory flag = s[i].liquidated ? " LIQUIDADA" : "";
                int256 eq = s[i].equity / 1e18;
                console.log(
                    string.concat(
                        "    dia ", vm.toString(i + 1),
                        " precio=", vm.toString(s[i].price / 1e18),
                        " HFx100=", vm.toString(s[i].healthFactor == type(uint256).max ? 0 : s[i].healthFactor * 100 / 1e18),
                        " equityUSD=", vm.toString(eq),
                        flag
                    )
                );
            }
        }
        console.log("IL con precio x2 (bps):", 10_000 - sim.lpValueRatio(2e18) * 10_000 / 1e18);
    }
}
