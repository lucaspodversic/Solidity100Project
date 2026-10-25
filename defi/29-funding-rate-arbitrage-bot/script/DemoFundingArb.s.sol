// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {FundingArbBot} from "../src/FundingArbBot.sol";
import {PerpMarket} from "../src/perp/PerpMarket.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title DemoFundingArb — simulación local completa del bot (sin broadcast)
/// @notice Corre: `forge script script/DemoFundingArb.s.sol -vv`
///   1. Despliega USDC mock, oráculo y dos perpetuos (A y B) con LPs.
///   2. Desbalancea los venues: A lleno de longs (+1 %/día), B de shorts (−1 %/día).
///   3. Loop de keeper cada 8 h durante 3 días: abre si `shouldOpen`, rebalancea si
///      `needsRebalance`, cierra si `shouldClose`. A mitad de camino el whale de A cierra
///      y el spread converge → el bot sale solo.
/// @dev Todo se hace con `vm.startPrank` sobre direcciones de `makeAddr` (nunca con la
///      dirección del script), igual que lo haría cada actor real.
contract DemoFundingArb is Script {
    address constant ETH = address(0xE7);
    uint256 constant P0 = 2000e18;

    MockERC20 usdc;
    PriceOracle oracle;
    PerpMarket a;
    PerpMarket b;
    FundingArbBot bot;

    address deployer = makeAddr("deployer");
    address operator = makeAddr("operator");
    address whaleA = makeAddr("whaleA");
    address whaleB = makeAddr("whaleB");
    address lp = makeAddr("lp");

    function run() external {
        _deploy();
        uint256 capital = usdc.balanceOf(address(bot));
        console2.log("Spread inicial (bps/dia):", bot.spreadPerDay() / 1e14);

        for (uint256 tick; tick < 9; tick++) {
            if (tick == 5) {
                // un actor externo cierra su long en A: el spread se comprime
                vm.startPrank(whaleA);
                a.closePosition(0);
                vm.stopPrank();
                console2.log("whaleA cerro; spread ahora (bps/dia):", bot.spreadPerDay() / 1e14);
            }
            _keeperTick(tick);
            vm.warp(vm.getBlockTimestamp() + 8 hours);
        }

        uint256 fin = usdc.balanceOf(address(bot));
        console2.log("Capital inicial USDC:", capital / 1e6);
        console2.log("Capital final USDC:  ", fin / 1e6);
        console2.log("PnL USDC:            ", (int256(fin) - int256(capital)) / 1e6);
    }

    /// @dev Lo que haría el bot off-chain en cada iteración (sólo lecturas + 1 tx).
    function _keeperTick(uint256 tick) internal {
        vm.startPrank(operator);
        if (bot.shouldOpen(50e18)) {
            uint256 px = a.price();
            bot.open(50e18, 50_000e6, px, 50);
            console2.log("tick", tick, "-> OPEN, edge bps/dia:", uint256(bot.edgePerDay() / 1e14));
        } else if (bot.shouldClose()) {
            uint256 back = bot.close();
            console2.log("tick", tick, "-> CLOSE, USDC devueltos:", back / 1e6);
        } else if (bot.needsRebalance()) {
            bot.rebalance(!bot.shortOnA(), 10_000e6);
            console2.log("tick", tick, "-> REBALANCE");
        } else if (bot.isOpen()) {
            console2.log("tick", tick, "-> HOLD, equity USDC:", uint256(bot.totalEquity()) / 1e6);
        }
        vm.stopPrank();
    }

    function _deploy() internal {
        vm.startPrank(deployer);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new PriceOracle();
        oracle.setMaxAge(3650 days);
        oracle.setPrice(ETH, P0);
        a = new PerpMarket(usdc, oracle, ETH, 0.01e18, 100e18);
        b = new PerpMarket(usdc, oracle, ETH, 0.01e18, 100e18);
        bot = new FundingArbBot(usdc, a, b, deployer, operator);
        usdc.mint(address(bot), 200_000e6);
        usdc.mint(lp, 2_000_000e6);
        usdc.mint(whaleA, 100_000e6);
        usdc.mint(whaleB, 300_000e6);
        vm.stopPrank();

        vm.startPrank(lp);
        usdc.approve(address(a), type(uint256).max);
        usdc.approve(address(b), type(uint256).max);
        a.lpDeposit(1_000_000e6);
        b.lpDeposit(1_000_000e6);
        vm.stopPrank();

        vm.startPrank(whaleA);
        usdc.approve(address(a), type(uint256).max);
        a.depositMargin(100_000e6);
        a.trade(200e18, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(whaleB);
        usdc.approve(address(b), type(uint256).max);
        b.depositMargin(300_000e6);
        b.trade(-100e18, 0);
        vm.stopPrank();
    }
}
