// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Raffle} from "../src/Raffle.sol";
import {VRFCoordinatorMock} from "../src/VRFCoordinatorMock.sol";
import {VRFConsumerBaseMinimal} from "../src/VRFInterfaces.sol";

contract RaffleTest is Test {
    Raffle raffle;
    VRFCoordinatorMock coord;
    address[4] players;

    function setUp() public {
        coord = new VRFCoordinatorMock();
        raffle = new Raffle(address(coord), 0.01 ether, 1 hours, keccak256("lane"), 1, 500_000);
        for (uint256 i; i < 4; i++) {
            players[i] = makeAddr(string.concat("p", vm.toString(i)));
            vm.deal(players[i], 1 ether);
        }
    }

    function _enterAll() internal {
        for (uint256 i; i < 4; i++) {
            vm.prank(players[i]);
            raffle.enter{value: 0.01 ether}();
        }
    }

    function test_Entrar() public {
        _enterAll();
        assertEq(raffle.playersCount(), 4);
        assertEq(raffle.playerAt(2), players[2]);
    }

    function test_RevertFeeIncorrecto() public {
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSelector(Raffle.WrongEntranceFee.selector, 1, 0.01 ether));
        raffle.enter{value: 1}();
    }

    function test_RevertUpkeepNoNecesario() public {
        _enterAll();
        vm.expectRevert(
            abi.encodeWithSelector(Raffle.UpkeepNotNeeded.selector, 0.04 ether, 4, Raffle.RaffleState.OPEN)
        );
        raffle.requestWinner();
    }

    function test_CicloCompleto() public {
        _enterAll();
        vm.warp(block.timestamp + 1 hours);
        assertTrue(raffle.checkUpkeep());
        uint256 req = raffle.requestWinner();
        assertEq(uint8(raffle.state()), uint8(Raffle.RaffleState.CALCULATING));

        // Durante el cálculo no se puede entrar.
        vm.prank(players[0]);
        vm.expectRevert(Raffle.RaffleNotOpen.selector);
        raffle.enter{value: 0.01 ether}();

        // Forzamos el número 6 => índice 6 % 4 = 2.
        uint256[] memory w = new uint256[](1);
        w[0] = 6;
        coord.fulfillRandomWordsWithOverride(req, w);
        assertEq(raffle.recentWinner(), players[2]);
        assertEq(players[2].balance, 1 ether - 0.01 ether + 0.04 ether);
        assertEq(raffle.playersCount(), 0);
        assertEq(uint8(raffle.state()), uint8(Raffle.RaffleState.OPEN));
    }

    function test_FulfillPseudoAleatorioDelMock() public {
        _enterAll();
        vm.warp(block.timestamp + 1 hours);
        uint256 req = raffle.requestWinner();
        coord.fulfillRandomWords(req);
        address w = raffle.recentWinner();
        bool esJugador;
        for (uint256 i; i < 4; i++) if (players[i] == w) esJugador = true;
        assertTrue(esJugador);
    }

    function test_SoloCoordinatorEntrega() public {
        uint256[] memory w = new uint256[](1);
        vm.expectRevert(
            abi.encodeWithSelector(VRFConsumerBaseMinimal.OnlyCoordinatorCanFulfill.selector, address(this), address(coord))
        );
        raffle.rawFulfillRandomWords(1, w);
    }

    function testFuzz_GanadorSiempreValido(uint256 rnd) public {
        _enterAll();
        vm.warp(block.timestamp + 1 hours);
        uint256 req = raffle.requestWinner();
        uint256[] memory w = new uint256[](1);
        w[0] = rnd;
        coord.fulfillRandomWordsWithOverride(req, w);
        assertEq(raffle.recentWinner(), players[rnd % 4]);
    }
}
