// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EtherReceiver, NoEtherAccepted, Sender} from "../src/EtherReceiver.sol";

contract EtherReceiverTest is Test {
    EtherReceiver r;
    Sender s;

    function setUp() public {
        r = new EtherReceiver();
        s = new Sender();
        vm.deal(address(this), 10 ether);
    }

    function test_DataVaciaVaAReceive() public {
        (bool ok,) = address(r).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(r.receiveCount(), 1);
        assertEq(r.fallbackCount(), 0);
    }

    function test_SelectorDesconocidoVaAFallback() public {
        (bool ok, bytes memory ret) = address(r).call{value: 1 wei}(abi.encodeWithSignature("noExiste(uint256)", 7));
        assertTrue(ok);
        assertEq(r.fallbackCount(), 1);
        // Con la firma `fallback(bytes) returns (bytes)` el retorno va crudo (sin re-codificar).
        assertEq(abi.decode(ret, (string)), "fallback ok");
        assertEq(bytes4(r.lastData()), bytes4(keccak256("noExiste(uint256)")));
    }

    function test_FuncionConocidaNoTocaFallback() public view {
        assertEq(r.hello(), "hola");
    }

    function test_FallbackNoPayableRechazaEth() public {
        NoEtherAccepted n = new NoEtherAccepted();
        (bool ok,) = address(n).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(n).call(hex"12345678");
        assertTrue(ok);
        assertEq(n.calls(), 1);
    }

    /// @notice transfer con 2300 gas no alcanza para el receive que escribe storage.
    function test_TransferFallaPorGas() public {
        vm.expectRevert();
        s.viaTransfer{value: 1 ether}(payable(address(r)));
    }

    function test_SendDevuelveFalse() public {
        bool ok = s.viaSend{value: 1 ether}(payable(address(r)));
        assertFalse(ok); // ¡el ETH queda en Sender si no se chequea!
        assertEq(address(s).balance, 1 ether);
    }

    function test_CallFunciona() public {
        bool ok = s.viaCall{value: 1 ether}(payable(address(r)));
        assertTrue(ok);
        assertEq(r.receiveCount(), 1);
        assertEq(address(r).balance, 1 ether);
    }
}
