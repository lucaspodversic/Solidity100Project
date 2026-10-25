// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SnapshotToken} from "../src/SnapshotToken.sol";

contract SnapshotTokenTest is Test {
    SnapshotToken t;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        t = new SnapshotToken(1_000 ether);
        t.transfer(alice, 100 ether);
    }

    function test_SaldosCongelados() public {
        uint256 s1 = t.snapshot();
        vm.prank(alice);
        t.transfer(bob, 60 ether);
        assertEq(t.balanceOfAt(alice, s1), 100 ether);
        assertEq(t.balanceOfAt(bob, s1), 0);
        assertEq(t.balanceOf(alice), 40 ether);
        assertEq(t.balanceOf(bob), 60 ether);
    }

    function test_VariosSnapshots() public {
        uint256 s1 = t.snapshot();
        vm.prank(alice);
        t.transfer(bob, 10 ether);
        uint256 s2 = t.snapshot();
        vm.prank(alice);
        t.transfer(bob, 20 ether);
        uint256 s3 = t.snapshot();
        assertEq(t.balanceOfAt(alice, s1), 100 ether);
        assertEq(t.balanceOfAt(alice, s2), 90 ether);
        assertEq(t.balanceOfAt(alice, s3), 70 ether);
        assertEq(t.balanceOfAt(bob, s2), 10 ether);
    }

    function test_SnapshotSinCambiosUsaSaldoActual() public {
        uint256 s1 = t.snapshot();
        t.snapshot();
        assertEq(t.balanceOfAt(alice, s1), 100 ether);
    }

    function test_SupplyEnSnapshot() public {
        // El supply no cambió tras el snapshot: se devuelve el total vigente.
        uint256 s1 = t.snapshot();
        assertEq(t.totalSupplyAt(s1), 1_000 ether);
    }

    function test_DobleVotoImposible() public {
        // Alice "vota" con su saldo en s1, transfiere a bob, y bob intenta votar con lo mismo.
        uint256 s1 = t.snapshot();
        uint256 votosAlice = t.balanceOfAt(alice, s1);
        vm.prank(alice);
        t.transfer(bob, 100 ether);
        uint256 votosBob = t.balanceOfAt(bob, s1);
        assertEq(votosAlice + votosBob, 100 ether); // los tokens movidos no suman doble
    }

    function test_RevertSnapshotInexistente() public {
        vm.expectRevert(abi.encodeWithSelector(SnapshotToken.NonexistentSnapshot.selector, 1));
        t.balanceOfAt(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(SnapshotToken.NonexistentSnapshot.selector, 0));
        t.totalSupplyAt(0);
    }

    function test_SoloOwnerSnapshot() public {
        vm.prank(alice);
        vm.expectRevert();
        t.snapshot();
    }

    function testFuzz_HistoricoConsistente(uint96 a, uint96 b) public {
        a = uint96(bound(a, 0, 100 ether));
        uint256 s1 = t.snapshot();
        vm.prank(alice);
        t.transfer(bob, a);
        b = uint96(bound(b, 0, a));
        uint256 s2 = t.snapshot();
        vm.prank(bob);
        t.transfer(alice, b);
        assertEq(t.balanceOfAt(alice, s1), 100 ether);
        assertEq(t.balanceOfAt(bob, s2), a);
        assertEq(t.balanceOf(bob), uint256(a) - b);
    }
}
