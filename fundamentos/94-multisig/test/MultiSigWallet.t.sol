// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

contract Counter {
    uint256 public n;
    function inc() external { n++; }
}

contract MultiSigWalletTest is Test {
    MultiSigWallet w;
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");
    address dest = makeAddr("dest");

    function setUp() public {
        address[] memory o = new address[](3);
        o[0] = a; o[1] = b; o[2] = c;
        w = new MultiSigWallet(o, 2);
        vm.deal(address(w), 10 ether);
    }

    function test_EnvioEthConDosFirmas() public {
        vm.prank(a);
        uint256 id = w.submit(dest, 1 ether, "");
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotEnoughConfirmations.selector, 1, 2));
        w.execute(id);
        vm.prank(b);
        w.confirm(id);
        vm.prank(c);
        w.execute(id);
        assertEq(dest.balance, 1 ether);
    }

    function test_LlamadaAContrato() public {
        Counter cnt = new Counter();
        vm.prank(a);
        uint256 id = w.submit(address(cnt), 0, abi.encodeCall(Counter.inc, ()));
        vm.prank(b);
        w.confirm(id);
        vm.prank(a);
        w.execute(id);
        assertEq(cnt.n(), 1);
    }

    function test_Revocar() public {
        vm.prank(a);
        uint256 id = w.submit(dest, 1 ether, "");
        vm.prank(b);
        w.confirm(id);
        vm.prank(b);
        w.revoke(id);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.NotEnoughConfirmations.selector, 1, 2));
        w.execute(id);
    }

    function test_NoDobleEjecucion() public {
        vm.prank(a);
        uint256 id = w.submit(dest, 1 ether, "");
        vm.prank(b);
        w.confirm(id);
        vm.prank(a);
        w.execute(id);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.AlreadyExecuted.selector, id));
        w.execute(id);
    }

    function test_SoloDuenos() public {
        vm.expectRevert(MultiSigWallet.NotOwner.selector);
        w.submit(dest, 1, "");
    }

    function test_AdminSoloViaMultisig() public {
        vm.prank(a);
        vm.expectRevert(MultiSigWallet.NotSelf.selector);
        w.addOwner(dest);
        // Por el camino correcto: transacción dirigida a la propia billetera.
        vm.prank(a);
        uint256 id = w.submit(address(w), 0, abi.encodeCall(MultiSigWallet.addOwner, (dest)));
        vm.prank(b);
        w.confirm(id);
        vm.prank(a);
        w.execute(id);
        assertTrue(w.isOwner(dest));
        assertEq(w.getOwners().length, 4);
    }

    function test_ConstructorInvalido() public {
        address[] memory o = new address[](2);
        o[0] = a; o[1] = a;
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidOwner.selector, a));
        new MultiSigWallet(o, 1);
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet.InvalidRequirement.selector, 2, 3));
        new MultiSigWallet(o, 3);
    }
}
