// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SimpleLottery} from "../src/SimpleLottery.sol";

contract SimpleLotteryTest is Test {
    SimpleLottery lot;
    address[3] jugadores;

    function setUp() public {
        lot = new SimpleLottery(0.1 ether, 1 days);
        jugadores[0] = makeAddr("a");
        jugadores[1] = makeAddr("b");
        jugadores[2] = makeAddr("c");
        for (uint256 i; i < 3; i++) vm.deal(jugadores[i], 1 ether);
    }

    function _entrarTodos() internal {
        for (uint256 i; i < 3; i++) {
            vm.prank(jugadores[i]);
            lot.enter{value: 0.1 ether}();
        }
    }

    function test_Entrar() public {
        _entrarTodos();
        assertEq(lot.playersCount(), 3);
        assertEq(address(lot).balance, 0.3 ether);
    }

    function test_RevertPrecioIncorrecto() public {
        vm.prank(jugadores[0]);
        vm.expectRevert(abi.encodeWithSelector(SimpleLottery.WrongTicketPrice.selector, 0.2 ether, 0.1 ether));
        lot.enter{value: 0.2 ether}();
    }

    function test_SorteoPagaPozoYReinicia() public {
        _entrarTodos();
        vm.warp(block.timestamp + 1 days);
        lot.pickWinner();
        address w = lot.lastWinner();
        assertEq(w.balance, 1 ether - 0.1 ether + 0.3 ether);
        assertEq(lot.playersCount(), 0);
        assertEq(lot.round(), 2);
    }

    function test_RevertSorteoAntesDeTiempo() public {
        _entrarTodos();
        vm.expectRevert(SimpleLottery.LotteryStillOpen.selector);
        lot.pickWinner();
    }

    function test_RevertSoloOrganizador() public {
        vm.warp(block.timestamp + 1 days);
        vm.prank(jugadores[0]);
        vm.expectRevert(SimpleLottery.NotOrganizer.selector);
        lot.pickWinner();
    }

    function test_RevertSinJugadores() public {
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(SimpleLottery.NoPlayers.selector);
        lot.pickWinner();
    }

    /// @notice DEMOSTRACIÓN DEL RIESGO: quien controla prevrandao (el
    ///         validador) elige al ganador. Aquí "manipulamos" prevrandao con
    ///         vm.prevrandao hasta que gana el jugador c.
    function test_AleatoriedadManipulable() public {
        _entrarTodos();
        vm.warp(block.timestamp + 1 days);
        uint256 objetivo = 2; // índice de "c"
        uint256 r;
        for (r = 0; r < 100; r++) {
            uint256 rnd = uint256(keccak256(abi.encodePacked(bytes32(r), block.timestamp, uint256(3), uint256(1))));
            if (rnd % 3 == objetivo) break;
        }
        vm.prevrandao(bytes32(r));
        lot.pickWinner();
        assertEq(lot.lastWinner(), jugadores[2], "el validador eligio al ganador");
    }
}
