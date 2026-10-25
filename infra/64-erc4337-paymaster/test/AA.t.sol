// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation, PostOpMode} from "../src/UserOperation.sol";
import {MiniEntryPoint} from "../src/MiniEntryPoint.sol";
import {SessionKeyAccount} from "../src/SessionKeyAccount.sol";
import {SponsorPaymaster} from "../src/SponsorPaymaster.sol";

/// @dev dApp de ejemplo (un juego) que la session key puede usar.
contract Game {
    mapping(address => uint256) public score;
    function play() external payable { score[msg.sender] += 1; }
    function admin() external pure {}
}

/// @title Tests del flujo ERC-4337 completo (EntryPoint mock + cuenta + paymaster)
contract AATest is Test {
    MiniEntryPoint ep;
    SessionKeyAccount acct;
    SponsorPaymaster pm;
    Game game;

    uint256 ownerPk = 0xA11CE;
    uint256 signerPk = 0x515;
    uint256 sessionPk = 0x5E55;
    address bundler = makeAddr("bundler");

    function setUp() public {
        vm.warp(1_000_000);
        vm.fee(1 gwei); // basefee
        ep = new MiniEntryPoint();
        acct = new SessionKeyAccount(ep, vm.addr(ownerPk));
        pm = new SponsorPaymaster(ep, vm.addr(signerPk), 0.05 ether);
        pm.deposit{value: 1 ether}();
        game = new Game();
    }

    // ---------------- helpers ----------------

    /// Arma una UserOp que llama `acct.execute(target, value, data)`.
    function _op(address target, uint256 value, bytes memory data) internal view returns (UserOperation memory op) {
        op.sender = address(acct);
        op.nonce = ep.getNonce(address(acct));
        op.callData = abi.encodeCall(SessionKeyAccount.execute, (target, value, data));
        op.callGasLimit = 200_000;
        op.verificationGasLimit = 150_000;
        op.preVerificationGas = 21_000;
        op.maxFeePerGas = 2 gwei;
        op.maxPriorityFeePerGas = 1 gwei;
    }

    /// Agrega paymasterAndData firmado por el backend.
    function _sponsor(UserOperation memory op, uint256 pk, uint48 until, uint48 afterTs) internal view {
        op.paymasterAndData = abi.encodePacked(address(pm), abi.encode(until, afterTs), new bytes(65));
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(pm.getHash(op, until, afterTs));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
        op.paymasterAndData = abi.encodePacked(address(pm), abi.encode(until, afterTs), r, s, v);
    }

    /// Firma con owner (65 bytes).
    function _signOwner(UserOperation memory op) internal view {
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(ep.getUserOpHash(op));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, h);
        op.signature = abi.encodePacked(r, s, v);
    }

    /// Firma con session key (85 bytes).
    function _signSession(UserOperation memory op, uint256 pk) internal view {
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(ep.getUserOpHash(op));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
        op.signature = abi.encodePacked(vm.addr(pk), r, s, v);
    }

    function _handle(UserOperation memory op) internal {
        UserOperation[] memory ops = new UserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        ep.handleOps(ops, payable(bundler));
    }

    function _addSession(uint48 until, uint128 maxValue, bool restrict) internal {
        bytes4[] memory sels = new bytes4[](restrict ? 1 : 0);
        if (restrict) sels[0] = Game.play.selector;
        vm.prank(vm.addr(ownerPk));
        acct.addSession(vm.addr(sessionPk), address(game), uint48(block.timestamp), until, maxValue, sels);
    }

    // ---------------- tests ----------------

    /// La cuenta sin ETH ejecuta gracias al paymaster; el bundler cobra.
    function test_SponsoredOwnerOp() public {
        assertEq(address(acct).balance, 0);
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signOwner(op);
        uint256 depBefore = ep.balanceOf(address(pm));
        _handle(op);
        assertEq(game.score(address(acct)), 1);
        assertGt(bundler.balance, 0, "bundler cobra");
        assertEq(depBefore - ep.balanceOf(address(pm)), bundler.balance, "paga el paymaster");
        // el paymaster ve el costo ANTES de su propio postOp (igual que en el EntryPoint real),
        // así que su contabilidad es apenas menor que lo cobrado.
        assertGt(pm.spent(address(acct)), 0);
        assertLe(pm.spent(address(acct)), bundler.balance);
        assertEq(ep.getNonce(address(acct)), 1);
    }

    /// Sin paymaster, la cuenta paga su propio gas.
    function test_SelfPaidOp() public {
        vm.deal(address(acct), 1 ether);
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _signOwner(op);
        _handle(op);
        assertEq(game.score(address(acct)), 1);
        assertLt(address(acct).balance, 1 ether);
        // el sobrante queda depositado a favor de la cuenta en el EntryPoint
        assertGt(ep.balanceOf(address(acct)), 0);
    }

    /// Replay: la misma UserOp no puede ejecutarse dos veces (nonce).
    function test_RevertWhen_Replay() public {
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signOwner(op);
        _handle(op);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA25 invalid account nonce"));
        _handle(op);
    }

    /// Firma de owner inválida => AA24.
    function test_RevertWhen_BadAccountSig() public {
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(ep.getUserOpHash(op));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, h);
        op.signature = abi.encodePacked(r, s, v);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handle(op);
    }

    /// Firma de paymaster de otro firmante => AA34.
    function test_RevertWhen_BadPaymasterSig() public {
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, 0xBAD, uint48(block.timestamp + 1 hours), 0);
        _signOwner(op);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA34 signature error"));
        _handle(op);
    }

    /// Patrocinio vencido => AA32.
    function test_RevertWhen_SponsorExpired() public {
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp - 1), 0);
        _signOwner(op);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA32 paymaster expired or not due"));
        _handle(op);
    }

    /// El presupuesto por cuenta se agota.
    function test_BudgetExhausted() public {
        pm.setBudget(0.0001 ether); // menor que maxCost de una op
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signOwner(op);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA33 reverted"));
        _handle(op);
    }

    /// Session key: puede jugar, patrocinada.
    function test_SessionKeyPlays() public {
        _addSession(uint48(block.timestamp + 1 days), 0, true);
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signSession(op, sessionPk);
        _handle(op);
        assertEq(game.score(address(acct)), 1);
    }

    /// Session key: no puede llamar otro destino.
    function test_RevertWhen_SessionKeyWrongTarget() public {
        _addSession(uint48(block.timestamp + 1 days), 0, false);
        UserOperation memory op = _op(makeAddr("thief"), 0, "");
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signSession(op, sessionPk);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handle(op);
    }

    /// Session key: selector no permitido.
    function test_RevertWhen_SessionKeyWrongSelector() public {
        _addSession(uint48(block.timestamp + 1 days), 0, true);
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.admin, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signSession(op, sessionPk);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handle(op);
    }

    /// Session key: vencida => AA22.
    function test_RevertWhen_SessionExpired() public {
        _addSession(uint48(block.timestamp + 10), 0, true);
        vm.warp(block.timestamp + 11);
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signSession(op, sessionPk);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA22 expired or not due"));
        _handle(op);
    }

    /// Session key revocada.
    function test_RevertWhen_SessionRevoked() public {
        _addSession(uint48(block.timestamp + 1 days), 0, true);
        vm.prank(vm.addr(ownerPk));
        acct.revokeSession(vm.addr(sessionPk));
        UserOperation memory op = _op(address(game), 0, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signSession(op, sessionPk);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handle(op);
    }

    /// Session key: tope de valor por operación.
    function test_RevertWhen_SessionValueTooHigh() public {
        vm.deal(address(acct), 1 ether);
        _addSession(uint48(block.timestamp + 1 days), 0.01 ether, true);
        UserOperation memory op = _op(address(game), 0.02 ether, abi.encodeCall(Game.play, ()));
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signSession(op, sessionPk);
        vm.expectRevert(abi.encodeWithSelector(MiniEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handle(op);
    }

    /// Si la ejecución revierte, la op igual se cobra (no se revierte el bundle).
    function test_ExecutionRevertStillCharged() public {
        UserOperation memory op = _op(address(game), 1 ether, abi.encodeCall(Game.play, ())); // la cuenta no tiene 1 ETH
        _sponsor(op, signerPk, uint48(block.timestamp + 1 hours), 0);
        _signOwner(op);
        _handle(op);
        assertEq(game.score(address(acct)), 0);
        assertGt(pm.spent(address(acct)), 0);
        assertEq(ep.getNonce(address(acct)), 1);
    }

    /// Solo el EntryPoint puede llamar validateUserOp y postOp.
    function test_RevertWhen_DirectValidation() public {
        UserOperation memory op = _op(address(game), 0, "");
        vm.expectRevert("solo EntryPoint");
        acct.validateUserOp(op, bytes32(0), 0);
        vm.expectRevert(SponsorPaymaster.NotEntryPoint.selector);
        pm.postOp(PostOpMode.opSucceeded, abi.encode(address(acct)), 1);
    }
}
