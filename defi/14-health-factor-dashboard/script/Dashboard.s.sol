// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {LendingPool} from "../src/protocol/LendingPool.sol";
import {JumpRateModel} from "../src/protocol/JumpRateModel.sol";
import {PriceOracle} from "../src/protocol/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {HealthFactorLens} from "../src/HealthFactorLens.sol";
import {Account_} from "../src/mocks/Account_.sol";

/// @title Dashboard — imprime el "dashboard" de salud en consola
/// @notice Modo demo (sin variables de entorno): despliega un mercado local con posiciones.
///         Modo real: `HF_LENS=0x... HF_USER=0x... forge script script/Dashboard.s.sol --rpc-url $RPC`
///         lee un lens ya desplegado (sólo `eth_call`, no envía transacciones).
contract Dashboard is Script {
    function run() external {
        address lensAddr = vm.envOr("HF_LENS", address(0));
        address user = vm.envOr("HF_USER", address(0));
        HealthFactorLens lens;
        if (lensAddr == address(0)) {
            (lens, user) = _demo();
        } else {
            lens = HealthFactorLens(lensAddr);
        }
        _print(lens, user);
    }

    function _demo() internal returns (HealthFactorLens lens, address user) {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        PriceOracle oracle = new PriceOracle();
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        JumpRateModel m = new JumpRateModel(0, 0.04e18, 0.75e18, 0.8e18);
        LendingPool pool = new LendingPool(oracle, address(0xBEEF));
        pool.listMarket(address(weth), 0.75e18, 0.8e18, 0.05e18, 0.1e18, m);
        pool.listMarket(address(usdc), 0.8e18, 0.85e18, 0.05e18, 0.1e18, m);
        Account_ lp = new Account_();
        usdc.mint(address(lp), 1_000_000e6);
        lp.deposit(pool, usdc, 1_000_000e6);
        Account_ a = new Account_();
        weth.mint(address(a), 10e18);
        a.deposit(pool, weth, 10e18);
        a.borrow(pool, usdc, 12_000e6);
        lens = new HealthFactorLens(pool);
        user = address(a);
    }

    function _print(HealthFactorLens lens, address user) internal view {
        HealthFactorLens.Dashboard memory d = lens.dashboard(user);
        console.log("=== Health Factor Dashboard ===");
        console.log("Cuenta:", user);
        for (uint256 i; i < d.lines.length; i++) {
            HealthFactorLens.AssetLine memory l = d.lines[i];
            if (l.supplied == 0 && l.borrowed == 0) continue;
            console.log(" activo", l.asset);
            console.log("   depositado USD:", l.suppliedUsd / 1e18, " adeudado USD:", l.borrowedUsd / 1e18);
        }
        console.log("Colateral USD:", d.collateralUsd / 1e18);
        console.log("Deuda USD:", d.debtUsd / 1e18);
        console.log("Disponible para pedir USD:", d.availableToBorrowUsd / 1e18);
        console.log("Health factor (x1000):", d.healthFactor / 1e15);
        string[5] memory names = ["Sin deuda", "Seguro", "Atencion", "Peligro", "LIQUIDABLE"];
        console.log("Riesgo:", names[uint256(d.risk)]);
        if (d.lines.length > 0 && d.lines[0].supplied > 0) {
            console.log("Precio de liquidacion del activo 0 (USD):", lens.liquidationPrice(user, d.lines[0].asset) / 1e18);
            uint256[] memory drops = new uint256[](4);
            drops[0] = 1000;
            drops[1] = 2000;
            drops[2] = 3000;
            drops[3] = 4000;
            uint256[] memory hfs = lens.stressTest(user, d.lines[0].asset, drops);
            for (uint256 i; i < 4; i++) {
                console.log(" caida % / HF x1000:", drops[i] / 100, hfs[i] / 1e15);
            }
        }
    }
}
