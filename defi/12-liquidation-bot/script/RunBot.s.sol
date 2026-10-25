// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {LendingPool} from "../src/protocol/LendingPool.sol";
import {JumpRateModel} from "../src/protocol/JumpRateModel.sol";
import {PriceOracle} from "../src/protocol/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {FlashLender} from "../src/mocks/FlashLender.sol";
import {OracleDex} from "../src/mocks/OracleDex.sol";
import {LiquidationBot} from "../src/LiquidationBot.sol";
import {Borrower} from "../src/mocks/Borrower.sol";

/// @title RunBot — simulación end-to-end del bot de liquidación
/// @notice Despliega un mercado local, abre posiciones, baja el precio de ETH, escanea y
///         liquida la mejor oportunidad. Representa el loop que un keeper off-chain haría:
///         `while (true) { ops = bot.scan(users); for op in ops if op.estProfit > gas: execute }`.
///         Uso: `forge script script/RunBot.s.sol -vv` (no hace broadcast).
contract RunBot is Script {
    function run() external {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        PriceOracle oracle = new PriceOracle();
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        JumpRateModel m = new JumpRateModel(0, 0.04e18, 0.75e18, 0.8e18);
        LendingPool pool = new LendingPool(oracle, address(0xBEEF));
        pool.listMarket(address(weth), 0.75e18, 0.8e18, 0.05e18, 0.1e18, m);
        pool.listMarket(address(usdc), 0.8e18, 0.85e18, 0.05e18, 0.1e18, m);

        Borrower supplier = new Borrower();
        usdc.mint(address(supplier), 1_000_000e6);
        supplier.supply(pool, usdc, 1_000_000e6);

        address[] memory users = new address[](4);
        uint256[4] memory debts = [uint256(15_000e6), 12_000e6, 14_500e6, 8_000e6];
        for (uint256 i; i < 4; i++) {
            Borrower b = new Borrower();
            users[i] = address(b);
            weth.mint(address(b), 10e18);
            b.open(pool, weth, usdc, 10e18, debts[i]);
        }

        FlashLender fl = new FlashLender(9);
        usdc.mint(address(fl), 1_000_000e6);
        OracleDex dex = new OracleDex(oracle);
        usdc.mint(address(dex), 1_000_000e6);
        weth.mint(address(dex), 1_000e18);
        LiquidationBot bot = new LiquidationBot(pool, fl, dex);

        console.log("ETH cae de 2000 a 1800 USD");
        oracle.setPrice(address(weth), 1800e18);

        LiquidationBot.Opportunity[] memory ops = bot.scan(users, address(usdc), address(weth));
        uint256 total;
        for (uint256 i; i < ops.length; i++) {
            console.log("cuenta", i, "HF (milesimas):", ops[i].healthFactor / 1e15);
            if (ops[i].estProfit > 1e6) {
                uint256 p = bot.execute(
                    LiquidationBot.Params(ops[i].user, address(usdc), address(weth), ops[i].repayAmount, 1e6)
                );
                console.log("  liquidada; ganancia USDC (centavos):", p / 1e4);
                total += p;
            } else {
                console.log("  sin oportunidad");
            }
        }
        console.log("Ganancia total USDC:", total / 1e6);
    }
}

