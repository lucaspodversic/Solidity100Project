// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IInterestRateModel} from "../src/IInterestRateModel.sol";
import {LinearModel} from "../src/models/LinearModel.sol";
import {KinkModel} from "../src/models/KinkModel.sol";
import {AdaptiveCurveModel} from "../src/models/AdaptiveCurveModel.sol";
import {RateSimulator} from "../src/RateSimulator.sol";

/// @title CompareModels — imprime curvas y un escenario de estrés
/// @notice `forge script script/CompareModels.s.sol` (simulación local, sin broadcast).
contract CompareModels is Script {
    function run() external {
        LinearModel lin = new LinearModel(0.02e18, 0.2e18);
        KinkModel kink = new KinkModel(0, 0.04e18, 0.75e18, 0.8e18);
        AdaptiveCurveModel ada = new AdaptiveCurveModel(0.9e18, 0.04e18, 50e18);
        RateSimulator sim = new RateSimulator();

        console.log("U(%)  | Lineal(bps) | Kink(bps) | Adaptive(bps)");
        for (uint256 u = 0; u <= 100; u += 10) {
            uint256 w = u * 1e16;
            console.log(
                string.concat(
                    vm.toString(u), "  | ", vm.toString(lin.borrowRate(w) / 1e14), " | ",
                    vm.toString(kink.borrowRate(w) / 1e14), " | ", vm.toString(ada.borrowRate(w) / 1e14)
                )
            );
        }

        RateSimulator.Step[] memory s = sim.rampScenario(0.5e18, 1e18, 30, 1 days);
        IInterestRateModel[] memory ms = new IInterestRateModel[](3);
        ms[0] = lin;
        ms[1] = kink;
        ms[2] = ada;
        RateSimulator.Result[] memory res = sim.compare(ms, s, 1_000_000e18, 0.1e18);
        console.log("Estres 30 dias U 50->100%, prestamo 1M:");
        for (uint256 i; i < 3; i++) {
            console.log(
                string.concat(
                    ms[i].name(), ": interes=", vm.toString(res[i].debtInterest / 1e18), " maxAPR(bps)=",
                    vm.toString(res[i].maxBorrowApr / 1e14)
                )
            );
        }
    }
}
