// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Cheatcodes de Foundry accesibles desde el actor.
Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
import {RevenueTracker} from "../src/RevenueTracker.sol";
import {MockToken, MockDex, MockLending} from "../src/MockFeeSources.sol";

/// @title Dashboard — "lectura" del tracker por consola
/// @notice Simula una semana de actividad en una EVM local y luego imprime un
///         dashboard leyendo SOLO funciones `view` del tracker (lo mismo que haría
///         un frontend con viem/ethers).
/// @dev Uso: `forge script script/Dashboard.s.sol --tc Dashboard -vv` (no transmite nada a ninguna red).
contract Dashboard is Script {
    function run() external {
        vm.warp(200 days);
        // Foundry prohíbe usar address(this) del script: delegamos en un actor efímero.
        Actor actor = new Actor();
        vm.deal(address(actor), 100 ether);
        actor.go();
    }
}

/// @notice Actor que simula la actividad e imprime el dashboard.
contract Actor {
    function go() external {
        RevenueTracker t = new RevenueTracker(address(this));
        MockToken usdc = new MockToken("USD Coin", "USDC");
        MockDex dex = new MockDex(t);
        MockLending lend = new MockLending(t);
        t.setSource(address(dex), "DEX", true);
        t.setSource(address(lend), "Lending", true);
        t.setShares(address(0xBEEF), 1);

        usdc.mint(address(this), 1e30);
        usdc.approve(address(dex), type(uint256).max);

        // 7 días de volumen creciente
        for (uint256 d; d < 7; ++d) {
            dex.swap(usdc, (d + 1) * 100_000e18);
            lend.repay{value: (d + 1) * 1 ether}();
            VM.warp(block.timestamp + 1 days);
        }
        VM.warp(block.timestamp - 1 days); // volver al último día con datos

        // ------- lectura -------
        console2.log("===== DASHBOARD DE INGRESOS =====");
        console2.log("USDC total (unidades):", t.totalRevenue(address(usdc)) / 1e18);
        console2.log("ETH total (wei):", t.totalRevenue(address(0)));
        console2.log("USDC ultimos 7 dias:", t.revenueLastDays(address(usdc), 7) / 1e18);
        uint256[] memory serie = t.revenueSeries(address(usdc), 7);
        for (uint256 i; i < serie.length; ++i) console2.log(" dia -", i, ":", serie[i] / 1e18);
        (address[] memory srcs, uint256[] memory amts) = t.breakdown(address(0));
        for (uint256 i; i < srcs.length; ++i) console2.log(" fuente ETH", srcs[i], amts[i]);
        // APR anualizado sobre un TVL hipotético de 10M USDC (en basis points)
        uint256 aprBps = (t.revenueLastDays(address(usdc), 7) * 365 / 7) * 10_000 / 10_000_000e18;
        console2.log("APR estimado (bps) sobre TVL 10M:", aprBps);
    }

    receive() external payable {}
}
