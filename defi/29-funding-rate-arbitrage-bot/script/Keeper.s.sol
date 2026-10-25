// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {FundingArbBot} from "../src/FundingArbBot.sol";

/// @title Keeper — una iteración del bot contra un despliegue real
/// @notice Pensado para correr por cron (p.ej. cada 10 min):
///   BOT=0x... SIZE=50000000000000000000 MARGIN=50000000000 \
///   forge script script/Keeper.s.sol --rpc-url $RPC --private-key $OPERATOR_PK --broadcast
///   (MARGIN en unidades de USDC: 50000e6 = 50000000000)
/// @dev Toma decisiones SOLO con las vistas del contrato; los límites duros (tamaño máximo,
///      apalancamiento, desviación de precio, spread posterior) los vuelve a chequear el
///      contrato, así que una key de operador comprometida no puede vaciar los fondos.
contract Keeper is Script {
    function run() external {
        FundingArbBot bot = FundingArbBot(vm.envAddress("BOT"));
        uint256 size = vm.envOr("SIZE", uint256(50e18));
        uint256 margin = vm.envOr("MARGIN", uint256(50_000e6));
        uint256 maxDevBps = vm.envOr("MAX_DEV_BPS", uint256(50));

        console2.log("spread bps/dia:", bot.spreadPerDay() / 1e14);
        vm.startBroadcast();
        if (bot.shouldOpen(size)) {
            bot.open(size, margin, bot.venueA().price(), maxDevBps);
            console2.log("OPEN");
        } else if (bot.shouldClose()) {
            bot.close();
            console2.log("CLOSE");
        } else if (bot.needsRebalance()) {
            bot.rebalance(!bot.shortOnA(), margin / 5);
            console2.log("REBALANCE");
        } else {
            console2.log("HOLD");
        }
        vm.stopBroadcast();
    }
}
