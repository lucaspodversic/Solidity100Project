// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {SpotPair, LendingVulnerable, TWAPOracle, LendingSafe} from "../src/Oracle.sol";

contract OracleTest is Test {
    SpotPair pair;
    LendingVulnerable vul;
    TWAPOracle twap;
    LendingSafe safe;

    function setUp() public {
        pair = new SpotPair(1000e18, 1000e18); // precio 1
        vul = new LendingVulnerable(address(pair));
        twap = new TWAPOracle(address(pair));
        safe = new LendingSafe(address(twap));
    }

    function test_FlashLoanManipulaSpot() public {
        // Atacante deposita 1 A de collateral
        vul.depositCollateral(1e18);
        // Sin manipulación solo puede pedir 0.5 B
        vm.expectRevert(bytes("LFV"));
        vul.borrow(1e18);
        // Manipula: saca A del pool comprando con mucha B → precio de A sube
        pair.swapBforA(5000e18); // drena A, sube spotPrice
        uint256 price = pair.spotPrice();
        assertTrue(price > 1e18);
        // Ahora con 1 A de collateral puede pedir mucho más
        vul.borrow(1e18); // pasa
        assertEq(vul.debtB(address(this)), 1e18);
    }

    function test_TWAPNoSeMueveEnMismaTx() public {
        safe.depositCollateral(1e18);
        twap.update();
        uint256 p0 = twap.lastPrice();
        // manipulación spot
        pair.swapBforA(5000e18);
        // En la misma tx, update() ve dt=0 → lastPrice no cambia al twap previo... 
        // Nuestro twap() llama update que con dt=0 no cambia lastPrice.
        // Pero lastPrice se setea a spot al final de update cuando dt>0.
        // Con dt=0, lastPrice queda en p0. Perfecto.
        vm.expectRevert(bytes("LFV"));
        safe.borrow(1e18); // sigue valorando a p0=1
        assertEq(twap.lastPrice(), p0);
    }
}
