// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlashLoanExecutor} from "../src/FlashLoanExecutor.sol";
import {SwapAdapter} from "../src/adapters/SwapAdapter.sol";
import {FlashLender} from "../src/mocks/FlashLender.sol";
import {SimpleAMM} from "../src/mocks/SimpleAMM.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title ArbRecipe — busca el tamaño óptimo de arbitraje y ejecuta la receta
/// @notice `forge script script/ArbRecipe.s.sol -vv` (simulación local, sin broadcast).
contract ArbRecipe is Script {
    function run() external {
        // Los scripts no pueden usar address(this): operamos como una cuenta simulada.
        address operator = makeAddr("operator");
        vm.startPrank(operator);
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        SimpleAMM a = new SimpleAMM(IERC20(address(weth)), IERC20(address(usdc)));
        SimpleAMM b = new SimpleAMM(IERC20(address(weth)), IERC20(address(usdc)));
        weth.mint(operator, 200e18);
        usdc.mint(operator, 420_000e6);
        weth.approve(address(a), type(uint256).max);
        usdc.approve(address(a), type(uint256).max);
        weth.approve(address(b), type(uint256).max);
        usdc.approve(address(b), type(uint256).max);
        a.seed(100e18, 200_000e6);
        b.seed(100e18, 220_000e6);
        FlashLender lender = new FlashLender(9);
        usdc.mint(address(lender), 1_000_000e6);
        FlashLoanExecutor ex = new FlashLoanExecutor();
        SwapAdapter sw = new SwapAdapter();
        ex.setAdapter(address(sw), true);
        ex.setLender(address(lender), true);

        // Búsqueda "off-chain" del tamaño óptimo usando solo quotes de vista.
        uint256 best;
        uint256 bestProfit;
        for (uint256 x = 1_000e6; x <= 20_000e6; x += 1_000e6) {
            uint256 wethOut = a.getAmountOut(address(usdc), x);
            uint256 back = b.getAmountOut(address(weth), wethOut);
            uint256 cost = x + lender.flashFee(address(usdc), x);
            if (back > cost && back - cost > bestProfit) {
                bestProfit = back - cost;
                best = x;
            }
        }
        console.log("Monto optimo USDC:", best / 1e6, "ganancia esperada:", bestProfit / 1e6);

        FlashLoanExecutor.Step[] memory s = new FlashLoanExecutor.Step[](2);
        s[0] = FlashLoanExecutor.Step(address(sw), abi.encode(address(a), address(usdc), best, uint256(0)));
        s[1] = FlashLoanExecutor.Step(address(sw), abi.encode(address(b), address(weth), sw.USE_PREV(), uint256(0)));
        uint256 p = ex.run(lender, address(usdc), best, s, 1);
        console.log("Ganancia real USDC:", p / 1e6);
        vm.stopPrank();
    }
}
