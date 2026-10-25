// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {YieldAggregator} from "../src/YieldAggregator.sol";
import {MockYieldVault} from "../src/mocks/MockYieldVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Ranking — despliega 4 fuentes simuladas, mide 30 días y muestra la tabla comparativa
/// @notice Uso: `forge script script/Ranking.s.sol -vv` (no transmite nada, corre en memoria).
contract Ranking is Script {
    function run() external {
        address operator = makeAddr("operator");
        vm.startPrank(operator);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        YieldAggregator agg = new YieldAggregator(IERC20(address(usdc)), 100_000e6);

        string[4] memory names = ["Blue-chip lending", "Curve LP", "Degen farm", "Vault nuevo"];
        uint256[4] memory tvl = [uint256(5_000_000e6), 2_000_000e6, 800_000e6, 40_000e6];
        uint256[4] memory apr = [uint256(450), 900, 4_500, 2_000];
        uint16[4] memory risk = [uint16(200), 1_500, 7_000, 3_000];
        MockYieldVault[4] memory v;
        for (uint256 i; i < 4; i++) {
            v[i] = new MockYieldVault(IERC20(address(usdc)), names[i]);
            usdc.mint(operator, tvl[i]);
            usdc.approve(address(v[i]), tvl[i]);
            v[i].deposit(tvl[i], operator);
            agg.addSource(IERC4626(address(v[i])), names[i], risk[i]);
        }
        for (uint256 i; i < 4; i++) v[i].simulateYield((tvl[i] * apr[i] * 30) / (10_000 * 365));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        agg.poke();
        vm.stopPrank();

        YieldAggregator.Row[] memory rows = agg.ranking();
        console.log("#  | fuente             | APY bps | riesgo bps | TVL USDC   | score bps | elegible");
        for (uint256 i; i < rows.length; i++) {
            console.log(string.concat(
                vm.toString(i + 1), "  | ", rows[i].name, " | ", vm.toString(rows[i].apyBps), " | ",
                vm.toString(rows[i].riskBps), " | ", vm.toString(rows[i].tvl / 1e6), " | ",
                vm.toString(rows[i].score), " | ", rows[i].eligible ? "si" : "no"
            ));
        }
        console.log("Mejor opcion:", agg.best().name);
    }
}
