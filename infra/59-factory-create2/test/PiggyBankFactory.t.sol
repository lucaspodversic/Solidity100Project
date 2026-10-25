// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {PiggyBank} from "../src/PiggyBank.sol";
import {PiggyBankFactory} from "../src/PiggyBankFactory.sol";

/// @title Tests del patrón Factory (CREATE, CREATE2 y clones)
contract PiggyBankFactoryTest is Test {
    PiggyBankFactory f;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint64 unlock;

    function setUp() public {
        f = new PiggyBankFactory();
        unlock = uint64(block.timestamp + 1 days);
    }

    /// CREATE: registra y configura bien.
    function test_Create() public {
        vm.prank(alice);
        address b = f.createBank(unlock);
        assertEq(PiggyBank(payable(b)).owner(), alice);
        assertEq(PiggyBank(payable(b)).factory(), address(f));
        assertTrue(f.isFromFactory(b));
        assertEq(f.totalBanks(), 1);
    }

    /// CREATE2: la dirección predicha coincide con la real.
    function test_Create2Predict() public {
        bytes32 salt = keccak256("mi-alcancia");
        address predicted = f.predictBank2(alice, unlock, salt);
        vm.prank(alice);
        address real = f.createBank2(unlock, salt);
        assertEq(real, predicted);
    }

    /// CREATE2: se puede mandar ETH a la dirección ANTES de desplegar (counterfactual).
    function test_Create2Counterfactual() public {
        bytes32 salt = bytes32(uint256(7));
        address predicted = f.predictBank2(alice, unlock, salt);
        vm.deal(address(this), 1 ether);
        payable(predicted).transfer(1 ether);
        vm.prank(alice);
        address real = f.createBank2(unlock, salt);
        assertEq(real.balance, 1 ether);
        vm.warp(unlock);
        vm.prank(alice);
        PiggyBank(payable(real)).withdraw();
        assertEq(alice.balance, 1 ether);
    }

    /// CREATE2: misma sal y mismos parámetros => segunda vez revierte (dirección ocupada).
    function test_RevertWhen_Create2SameSaltTwice() public {
        vm.startPrank(alice);
        f.createBank2(unlock, bytes32(0));
        vm.expectRevert();
        f.createBank2(unlock, bytes32(0));
        vm.stopPrank();
    }

    /// La sal está ligada al usuario: bob con la misma sal obtiene otra dirección.
    function test_SaltBoundToSender() public {
        vm.prank(alice);
        address a = f.createBankClone(unlock, bytes32(0));
        vm.prank(bob);
        address b = f.createBankClone(unlock, bytes32(0));
        assertTrue(a != b);
    }

    /// Clon: predicción, inicialización y no-reinicialización.
    function test_Clone() public {
        bytes32 salt = bytes32(uint256(1));
        address predicted = f.predictClone(alice, salt);
        vm.prank(alice);
        address c = f.createBankClone(unlock, salt);
        assertEq(c, predicted);
        assertEq(PiggyBank(payable(c)).owner(), alice);
        vm.expectRevert(PiggyBank.AlreadyInitialized.selector);
        PiggyBank(payable(c)).initialize(bob, 0);
    }

    /// La implementación está bloqueada.
    function test_ImplementationLocked() public {
        PiggyBank impl = PiggyBank(payable(f.implementation())); // leer antes del expectRevert
        vm.expectRevert(PiggyBank.AlreadyInitialized.selector);
        impl.initialize(bob, 0);
    }

    /// Retiro antes de tiempo y por no-dueño revierte.
    function test_WithdrawRules() public {
        vm.prank(alice);
        address b = f.createBank(unlock);
        vm.deal(b, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PiggyBank.StillLocked.selector, unlock));
        PiggyBank(payable(b)).withdraw();
        vm.warp(unlock);
        vm.prank(bob);
        vm.expectRevert(PiggyBank.NotOwner.selector);
        PiggyBank(payable(b)).withdraw();
    }

    /// Comparación de gas entre los tres modos (se imprime con -vv).
    function test_GasComparison() public {
        vm.startPrank(alice);
        uint256 g0 = gasleft();
        f.createBank(unlock);
        uint256 gCreate = g0 - gasleft();
        g0 = gasleft();
        f.createBank2(unlock, bytes32(uint256(9)));
        uint256 gCreate2 = g0 - gasleft();
        g0 = gasleft();
        f.createBankClone(unlock, bytes32(uint256(9)));
        uint256 gClone = g0 - gasleft();
        vm.stopPrank();
        console2.log("gas CREATE :", gCreate);
        console2.log("gas CREATE2:", gCreate2);
        console2.log("gas CLONE  :", gClone);
        assertLt(gClone, gCreate); // el clon siempre es más barato
        assertEq(f.getBanksOf(alice).length, 3);
    }

    /// Fuzz: la predicción de CREATE2 es correcta para cualquier sal.
    function testFuzz_PredictMatches(bytes32 salt, uint64 t) public {
        address p = f.predictBank2(alice, t, salt);
        vm.prank(alice);
        assertEq(f.createBank2(t, salt), p);
    }
}
