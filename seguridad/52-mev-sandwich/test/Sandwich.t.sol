// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {MiniAMM} from "../src/AMM.sol";

contract SandwichTest is Test {
    MiniAMM amm;

    function setUp() public {
        amm = new MiniAMM(1000e18, 1000e18);
    }

    function test_SandwichExtraeValor() public {
        uint256 victimIn = 50e18;
        uint256 spotOut = (victimIn * amm.reserveB()) / (amm.reserveA() + victimIn);
        uint256 minOut = (spotOut * 90) / 100; // 10% tolerancia (víctima descuidada)

        // FRONT-RUN moderado
        uint256 atkIn = 40e18;
        uint256 atkOut1 = amm.swapAforB(atkIn, 0);

        // VÍCTIMA
        uint256 victimOut = amm.swapAforB(victimIn, minOut);

        // BACK-RUN
        uint256 atkOut2 = amm.swapBforA(atkOut1, 0);

        assertTrue(atkOut2 > atkIn, "profit");
        assertTrue(victimOut < spotOut, "victim peor");
    }

    function test_SlippageBajoBloqueaSandwich() public {
        uint256 victimIn = 50e18;
        uint256 spotOut = (victimIn * amm.reserveB()) / (amm.reserveA() + victimIn);
        uint256 minOutTight = (spotOut * 99) / 100;

        amm.swapAforB(200e18, 0);
        vm.expectRevert(bytes("slippage"));
        amm.swapAforB(victimIn, minOutTight);
    }
}
