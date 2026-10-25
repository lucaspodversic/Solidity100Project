// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {DonationDAO} from "../src/DonationDAO.sol";

contract DonationTest is Test {
    DonationDAO dao;
    address a = makeAddr("a");
    address b = makeAddr("b");
    address p1 = makeAddr("p1");
    address p2 = makeAddr("p2");

    function setUp() public {
        dao = new DonationDAO(1 days);
        dao.addProject(payable(p1), "Escuela");
        dao.addProject(payable(p2), "Hospital");
        vm.deal(a, 5 ether); vm.deal(b, 5 ether);
    }

    function test_Flujo() public {
        vm.prank(a); dao.donate{value: 3 ether}();
        vm.prank(b); dao.donate{value: 1 ether}();
        vm.prank(a); dao.allocate(0, 2 ether); // escuela
        vm.prank(a); dao.allocate(1, 1 ether); // hospital
        vm.prank(b); dao.allocate(1, 1 ether); // hospital
        // hospital = 2, escuela = 2 → empate, gana el de menor id (0) por el loop
        // a: 2 a escuela, 1 a hospital; b: 1 a hospital → escuela=2, hospital=2
        vm.warp(block.timestamp + 1 days);
        dao.finalize();
        // Con empate, best empieza en 0 y solo actualiza si >, así que gana 0 (escuela)
        assertEq(dao.winnerId(), 0);
        assertEq(p1.balance, 4 ether);
    }
}
