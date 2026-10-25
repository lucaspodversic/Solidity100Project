// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

/// @dev Contrato objetivo para probar llamadas con datos.
contract Counter {
    uint256 public n;
    function inc(uint256 by) external payable { n += by; }
    function boom() external pure { revert("boom"); }
}

/// @dev Atacante que intenta reentrar en executeTransaction al recibir ETH.
contract Reenterer {
    MultiSigWallet public w;
    uint256 public txId;
    bool public reentered;
    constructor(MultiSigWallet _w) { w = _w; }
    function setTx(uint256 id) external { txId = id; }
    receive() external payable {
        // Intento de reentrada: debe fallar (no es owner y además hay lock).
        try w.executeTransaction(txId) { reentered = true; } catch {}
    }
}

/// @title Tests de la MultiSigWallet
contract MultiSigWalletTest is Test {
    MultiSigWallet w;
    Counter c;
    address a = makeAddr("alice");
    address b = makeAddr("bob");
    address d = makeAddr("dave");
    address e = makeAddr("eve");

    function setUp() public {
        address[] memory o = new address[](3);
        o[0] = a; o[1] = b; o[2] = d;
        w = new MultiSigWallet(o, 2); // 2 de 3
        c = new Counter();
        vm.deal(address(w), 10 ether);
    }

    /// Flujo feliz: propone, confirma el segundo, ejecuta.
    function test_SubmitConfirmExecute() public {
        vm.prank(a);
        uint256 id = w.submitTransaction(address(c), 1 ether, abi.encodeCall(Counter.inc, (5)));
        vm.prank(b);
        w.confirmTransaction(id);
        vm.prank(d);
        w.executeTransaction(id);
        assertEq(c.n(), 5);
        assertEq(address(c).balance, 1 ether);
        (, , , bool executed, uint256 n) = w.getTransaction(id);
        assertTrue(executed);
        assertEq(n, 2);
    }

    /// No se puede ejecutar con menos confirmaciones que el umbral.
    function test_RevertWhen_NotEnoughConfirmations() public {
        vm.prank(a);
        uint256 id = w.submitTransaction(address(c), 0, abi.encodeCall(Counter.inc, (1)));
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotEnoughConfirmations.selector, 1, 2));
        w.executeTransaction(id);
    }

    /// Un no-owner no puede proponer.
    function test_RevertWhen_NotOwnerSubmits() public {
        vm.prank(e);
        vm.expectRevert(MultiSigWallet.NotOwner.selector);
        w.submitTransaction(address(c), 0, "");
    }

    /// No se puede confirmar dos veces.
    function test_RevertWhen_DoubleConfirm() public {
        vm.prank(a);
        uint256 id = w.submitTransaction(address(c), 0, "");
        vm.prank(a);
        vm.expectRevert(MultiSigWallet.TxAlreadyConfirmed.selector);
        w.confirmTransaction(id);
    }

    /// Revocar reduce las confirmaciones.
    function test_Revoke() public {
        vm.prank(a);
        uint256 id = w.submitTransaction(address(c), 0, "");
        vm.prank(b);
        w.confirmTransaction(id);
        vm.prank(b);
        w.revokeConfirmation(id);
        assertEq(w.validConfirmations(id), 1);
        vm.prank(a);
        vm.expectRevert();
        w.executeTransaction(id);
    }

    /// No se puede ejecutar dos veces.
    function test_RevertWhen_DoubleExecute() public {
        vm.prank(a);
        uint256 id = w.submitTransaction(address(c), 0, abi.encodeCall(Counter.inc, (1)));
        vm.prank(b);
        w.confirmTransaction(id);
        vm.prank(a);
        w.executeTransaction(id);
        vm.prank(a);
        vm.expectRevert(MultiSigWallet.TxAlreadyExecuted.selector);
        w.executeTransaction(id);
    }

    /// Si la llamada falla, revierte y queda reintentable.
    function test_FailedCallRevertsAndStaysPending() public {
        vm.prank(a);
        uint256 id = w.submitTransaction(address(c), 0, abi.encodeCall(Counter.boom, ()));
        vm.prank(b);
        w.confirmTransaction(id);
        vm.prank(a);
        vm.expectRevert();
        w.executeTransaction(id);
        (, , , bool executed,) = w.getTransaction(id);
        assertFalse(executed);
    }

    /// La administración solo es posible vía multifirma.
    function test_AdminOnlyViaWallet() public {
        vm.prank(a);
        vm.expectRevert(MultiSigWallet.NotWallet.selector);
        w.addOwner(e);

        vm.prank(a);
        uint256 id = w.submitTransaction(address(w), 0, abi.encodeCall(MultiSigWallet.addOwner, (e)));
        vm.prank(b);
        w.confirmTransaction(id);
        vm.prank(a);
        w.executeTransaction(id);
        assertTrue(w.isOwner(e));
        assertEq(w.getOwners().length, 4);
    }

    /// Confirmaciones de un owner removido dejan de contar.
    function test_RemovedOwnerConfirmationNotCounted() public {
        // tx pendiente confirmada por a y d
        vm.prank(a);
        uint256 pending = w.submitTransaction(address(c), 0, abi.encodeCall(Counter.inc, (1)));
        vm.prank(d);
        w.confirmTransaction(pending);
        // quitamos a d
        vm.prank(a);
        uint256 rm = w.submitTransaction(address(w), 0, abi.encodeCall(MultiSigWallet.removeOwner, (d)));
        vm.prank(b);
        w.confirmTransaction(rm);
        vm.prank(a);
        w.executeTransaction(rm);
        assertFalse(w.isOwner(d));
        assertEq(w.validConfirmations(pending), 1);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotEnoughConfirmations.selector, 1, 2));
        w.executeTransaction(pending);
    }

    /// Cambio de umbral vía multifirma y validación de umbral inválido.
    function test_ChangeThreshold() public {
        vm.prank(a);
        uint256 id = w.submitTransaction(address(w), 0, abi.encodeCall(MultiSigWallet.changeThreshold, (3)));
        vm.prank(b);
        w.confirmTransaction(id);
        vm.prank(a);
        w.executeTransaction(id);
        assertEq(w.threshold(), 3);
    }

    /// Constructor rechaza configuraciones inválidas.
    function test_ConstructorValidation() public {
        address[] memory o = new address[](2);
        o[0] = a; o[1] = a;
        vm.expectRevert(MultiSigWallet.DuplicateOwner.selector);
        new MultiSigWallet(o, 1);
        o[1] = b;
        vm.expectRevert(MultiSigWallet.InvalidThreshold.selector);
        new MultiSigWallet(o, 3);
        o[1] = address(0);
        vm.expectRevert(MultiSigWallet.InvalidOwner.selector);
        new MultiSigWallet(o, 1);
    }

    /// Reentrada desde el destinatario no logra re-ejecutar.
    function test_ReentrancyBlocked() public {
        Reenterer r = new Reenterer(w);
        vm.prank(a);
        uint256 id = w.submitTransaction(address(r), 1 ether, "");
        r.setTx(id);
        vm.prank(b);
        w.confirmTransaction(id);
        vm.prank(a);
        w.executeTransaction(id);
        assertFalse(r.reentered());
        assertEq(address(r).balance, 1 ether);
    }

    /// Recepción de ETH emite evento y suma balance.
    function test_Deposit() public {
        vm.deal(e, 1 ether);
        vm.prank(e);
        (bool ok,) = address(w).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(w).balance, 11 ether);
    }

    /// Fuzz: cualquier no-owner es rechazado.
    function testFuzz_NonOwnerCannotConfirm(address x) public {
        vm.assume(!w.isOwner(x));
        vm.prank(a);
        uint256 id = w.submitTransaction(address(c), 0, "");
        vm.prank(x);
        vm.expectRevert(MultiSigWallet.NotOwner.selector);
        w.confirmTransaction(id);
    }
}
