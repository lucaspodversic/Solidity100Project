// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BankWithStrings, BankWithCustomErrors, Unauthorized} from "../src/CustomErrors.sol";

contract CustomErrorsTest is Test {
    BankWithStrings s;
    BankWithCustomErrors c;
    address alice = makeAddr("alice");

    function setUp() public {
        s = new BankWithStrings();
        c = new BankWithCustomErrors();
    }

    function test_SelectoresYArgumentos() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BankWithCustomErrors.InsufficientBalance.selector, 0, 1 ether));
        c.withdraw(1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, alice));
        c.adminOnly();

        vm.expectRevert(bytes("BankWithStrings: saldo insuficiente para retirar"));
        s.withdraw(1 ether);
    }

    /// @notice El bytecode desplegado con errores personalizados es más chico.
    function test_BytecodeMasChico() public view {
        uint256 a = address(s).code.length;
        uint256 b = address(c).code.length;
        console2.log("bytecode strings      :", a);
        console2.log("bytecode custom errors:", b);
        assertLt(b, a);
    }

    /// @notice La reversión con error personalizado consume menos gas y
    ///         devuelve menos bytes de revert data.
    function test_RevertMasBarato() public {
        uint256 g0 = gasleft();
        try s.deposit() {} catch (bytes memory r1) {
            uint256 gasStr = g0 - gasleft();
            uint256 g1 = gasleft();
            try c.deposit() {} catch (bytes memory r2) {
                uint256 gasErr = g1 - gasleft();
                console2.log("gas revert string:", gasStr, "bytes:", r1.length);
                console2.log("gas revert custom:", gasErr, "bytes:", r2.length);
                assertLt(r2.length, r1.length);
                assertEq(r2.length, 4); // solo el selector
                assertLt(gasErr, gasStr);
                return;
            }
        }
        revert("se esperaban reversiones");
    }

    function test_FlujoNormalIdentico() public {
        vm.deal(alice, 2 ether);
        vm.startPrank(alice);
        s.deposit{value: 1 ether}();
        c.deposit{value: 1 ether}();
        s.withdraw(1 ether);
        c.withdraw(1 ether);
        vm.stopPrank();
        assertEq(alice.balance, 2 ether);
    }
}
