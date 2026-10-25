// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Multicall} from "../src/Multicall.sol";
import {PackedMulticall, PackedCodec} from "../src/PackedMulticall.sol";
import {Target, SafeBank, VulnerableBank} from "../src/mocks/Mocks.sol";

/// @title Tests de Multicall, PackedMulticall y SelfMulticall
contract MulticallTest is Test {
    Multicall mc;
    PackedMulticall pmc;
    PackedCodec codec;
    Target t;
    address user = makeAddr("user");

    function setUp() public {
        mc = new Multicall();
        pmc = new PackedMulticall();
        codec = new PackedCodec();
        t = new Target();
        vm.deal(user, 100 ether);
    }

    function _calls(uint256 n) internal view returns (Multicall.Call[] memory cs) {
        cs = new Multicall.Call[](n);
        for (uint256 i; i < n; i++) {
            cs[i] = Multicall.Call(address(t), abi.encodeCall(Target.inc, (1)));
        }
    }

    function test_Aggregate() public {
        (uint256 bn, bytes[] memory r) = mc.aggregate(_calls(3));
        assertEq(bn, block.number);
        assertEq(abi.decode(r[2], (uint256)), 3);
        assertEq(t.count(), 3);
    }

    function test_AggregateRevertsAtomically() public {
        Multicall.Call[] memory cs = _calls(2);
        cs[1].callData = abi.encodeCall(Target.fail, ());
        vm.expectRevert();
        mc.aggregate(cs);
        assertEq(t.count(), 0, "atomico: nada se aplico");
    }

    function test_TryAggregateToleratesFailure() public {
        Multicall.Call[] memory cs = _calls(2);
        cs[0].callData = abi.encodeCall(Target.fail, ());
        Multicall.Result[] memory r = mc.tryAggregate(false, cs);
        assertFalse(r[0].success);
        assertTrue(r[1].success);
        assertEq(t.count(), 1);
    }

    function test_Aggregate3AllowFailure() public {
        Multicall.Call3[] memory cs = new Multicall.Call3[](2);
        cs[0] = Multicall.Call3(address(t), true, abi.encodeCall(Target.fail, ()));
        cs[1] = Multicall.Call3(address(mc), false, abi.encodeCall(Multicall.getEthBalance, (user)));
        Multicall.Result[] memory r = mc.aggregate3(cs);
        assertFalse(r[0].success);
        assertEq(abi.decode(r[1].returnData, (uint256)), 100 ether);
        cs[0].allowFailure = false;
        vm.expectRevert();
        mc.aggregate3(cs);
    }

    function test_Aggregate3ValueExactValue() public {
        Multicall.Call3Value[] memory cs = new Multicall.Call3Value[](2);
        cs[0] = Multicall.Call3Value(address(t), false, 1 ether, abi.encodeCall(Target.pay, ()));
        cs[1] = Multicall.Call3Value(address(t), false, 2 ether, abi.encodeCall(Target.pay, ()));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Multicall.ValueMismatch.selector, 4 ether, 3 ether));
        mc.aggregate3Value{value: 4 ether}(cs);
        vm.prank(user);
        mc.aggregate3Value{value: 3 ether}(cs);
        assertEq(t.received(address(mc)), 3 ether);
        assertEq(address(mc).balance, 0);
    }

    function test_Aggregate3ValueRefundsFailed() public {
        Multicall.Call3Value[] memory cs = new Multicall.Call3Value[](2);
        cs[0] = Multicall.Call3Value(address(t), true, 1 ether, abi.encodeCall(Target.fail, ()));
        cs[1] = Multicall.Call3Value(address(t), false, 2 ether, abi.encodeCall(Target.pay, ()));
        vm.prank(user);
        mc.aggregate3Value{value: 3 ether}(cs);
        assertEq(user.balance, 98 ether, "se devolvio el ETH de la llamada fallida");
        assertEq(address(mc).balance, 0);
    }

    function test_PackedMulticallMatches() public {
        address[] memory ts = new address[](3);
        bytes[] memory ds = new bytes[](3);
        for (uint256 i; i < 3; i++) {
            ts[i] = address(t);
            ds[i] = abi.encodeCall(Target.inc, (2));
        }
        bytes memory packed = codec.encode(ts, ds);
        (bool ok, bytes memory out) = address(pmc).call(packed);
        assertTrue(ok);
        // fallback(bytes) devuelve los bytes crudos (sin codificación ABI)
        bytes[] memory res = codec.decode(out);
        assertEq(res.length, 3);
        assertEq(abi.decode(res[2], (uint256)), 6);
    }

    function test_PackedMulticallMalformedReverts() public {
        (bool ok,) = address(pmc).call(hex"0102030405");
        assertFalse(ok);
    }

    function test_PackedMulticallFailurePropagates() public {
        address[] memory ts = new address[](1);
        bytes[] memory ds = new bytes[](1);
        ts[0] = address(t);
        ds[0] = abi.encodeCall(Target.fail, ());
        (bool ok,) = address(pmc).call(codec.encode(ts, ds));
        assertFalse(ok);
    }

    /// @notice El formato empaquetado reduce el calldata (clave en rollups).
    function test_PackedCalldataIsSmaller() public view {
        address[] memory ts = new address[](10);
        bytes[] memory ds = new bytes[](10);
        Multicall.Call[] memory cs = new Multicall.Call[](10);
        for (uint256 i; i < 10; i++) {
            ts[i] = address(t);
            ds[i] = abi.encodeCall(Target.value, ());
            cs[i] = Multicall.Call(address(t), ds[i]);
        }
        uint256 abiLen = abi.encodeCall(Multicall.aggregate, (cs)).length;
        uint256 packedLen = codec.encode(ts, ds).length;
        console.log("calldata ABI:", abiLen, "empaquetado:", packedLen);
        assertLt(packedLen * 4, abiLen, "al menos 4x mas chico");
    }

    function test_SelfMulticallPreservesSender() public {
        SafeBank bank = new SafeBank();
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(SafeBank.addPoints, (5));
        d[1] = abi.encodeCall(SafeBank.addPoints, (7));
        vm.prank(user);
        bank.multicall(d);
        assertEq(bank.points(user), 12);
    }

    /// @notice Ataque de reutilización de msg.value: 1 ETH acreditado 3 veces.
    function test_MsgValueReuseAttackOnVulnerable() public {
        VulnerableBank vb = new VulnerableBank();
        vm.deal(address(vb), 10 ether); // fondos de otros usuarios
        bytes[] memory d = new bytes[](3);
        for (uint256 i; i < 3; i++) {
            d[i] = abi.encodeCall(VulnerableBank.deposit, ());
        }
        vm.prank(user);
        vb.multicall{value: 1 ether}(d);
        assertEq(vb.balance(user), 3 ether, "vulnerable: credito triple");
    }

    /// @notice Defensa: SafeBank.multicall no es payable, no se puede enviar ETH.
    function test_SafeBankRejectsValue() public {
        SafeBank bank = new SafeBank();
        bytes[] memory d = new bytes[](1);
        d[0] = abi.encodeCall(SafeBank.deposit, ());
        vm.prank(user);
        (bool ok,) = address(bank).call{value: 1 ether}(abi.encodeCall(bank.multicall, (d)));
        assertFalse(ok);
    }

    function testFuzz_AggregateN(uint8 n) public {
        n = uint8(bound(n, 1, 40));
        mc.aggregate(_calls(n));
        assertEq(t.count(), n);
    }
}
