// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentCred} from "../src/AgentCred.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract AgentCredTest is Test {
    AgentCred ac;
    address gov = makeAddr("gov");
    address owner = makeAddr("owner");
    address client = makeAddr("client");
    uint256 verifierPk = 0xA11CE;
    uint256 enclavePk = 0xE0C1A7E; // clave generada "dentro del TEE"
    address enclave;
    bytes32 constant M1 = keccak256("mrenclave-v1");
    bytes32 constant M2 = keccak256("mrenclave-v2");
    uint256 id;

    function setUp() public {
        vm.warp(1_700_000_000);
        ac = new AgentCred(gov);
        enclave = vm.addr(enclavePk);
        vm.startPrank(gov);
        ac.setVerifier(vm.addr(verifierPk), true);
        ac.setMeasurement(M1, true);
        ac.setMeasurement(M2, true);
        vm.stopPrank();
        vm.prank(owner);
        id = ac.register("ipfs://agent-card");
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 d = MessageHashUtils.toTypedDataHash(ac.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _sigs(uint256 vPk, uint256 kPk, bytes32 m, uint64 exp, address bindOwner)
        internal
        view
        returns (bytes memory vs, bytes memory ks)
    {
        vs = _sign(vPk, keccak256(abi.encode(ac.ATTESTATION_TYPEHASH(), id, vm.addr(kPk), m, exp)));
        ks = _sign(kPk, keccak256(abi.encode(ac.BINDING_TYPEHASH(), id, bindOwner)));
    }

    function _attest(bytes32 m) internal {
        uint64 exp = uint64(block.timestamp + 30 days);
        (bytes memory vs, bytes memory ks) = _sigs(verifierPk, enclavePk, m, exp, owner);
        vm.prank(owner);
        ac.attest(id, enclave, m, exp, vs, ks);
    }

    function _receipt(bytes32 taskId, address c) internal view returns (bytes memory) {
        return _sign(enclavePk, keccak256(abi.encode(ac.RECEIPT_TYPEHASH(), id, taskId, c)));
    }

    function test_AttestAndTrust() public {
        assertFalse(ac.isTrusted(id));
        _attest(M1);
        assertTrue(ac.isTrusted(id));
        vm.warp(block.timestamp + 31 days);
        assertFalse(ac.isTrusted(id), "expira");
    }

    function test_RevertWhen_FakeVerifier() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        (bytes memory vs, bytes memory ks) = _sigs(0xBAD, enclavePk, M1, exp, owner);
        vm.prank(owner);
        vm.expectRevert(AgentCred.BadVerifier.selector);
        ac.attest(id, enclave, M1, exp, vs, ks);
    }

    function test_RevertWhen_NoKeyPossession() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory vs = _sign(verifierPk, keccak256(abi.encode(ac.ATTESTATION_TYPEHASH(), id, enclave, M1, exp)));
        // binding firmado por otra clave (quien copió la atestación no tiene la clave del enclave)
        bytes memory ks = _sign(0xBEEF, keccak256(abi.encode(ac.BINDING_TYPEHASH(), id, owner)));
        vm.prank(owner);
        vm.expectRevert(AgentCred.BadBinding.selector);
        ac.attest(id, enclave, M1, exp, vs, ks);
    }

    function test_RevertWhen_UnapprovedMeasurement() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes32 bad = keccak256("build-no-auditado");
        (bytes memory vs, bytes memory ks) = _sigs(verifierPk, enclavePk, bad, exp, owner);
        vm.prank(owner);
        vm.expectRevert(AgentCred.MeasurementNotApproved.selector);
        ac.attest(id, enclave, bad, exp, vs, ks);
    }

    function test_RevokeMeasurementKillsTrust() public {
        _attest(M1);
        vm.prank(gov);
        ac.setMeasurement(M1, false);
        assertFalse(ac.isTrusted(id));
    }

    function test_RateWithReceipt() public {
        _attest(M1);
        bytes memory r = _receipt("task-1", client);
        vm.prank(client);
        ac.rate(id, "task-1", 5, r);
        bytes memory r2 = _receipt("task-2", client);
        vm.prank(client);
        ac.rate(id, "task-2", 4, r2);
        (uint256 avg, uint256 n) = ac.reputation(id);
        assertEq(avg, 450);
        assertEq(n, 2);
    }

    function test_RevertWhen_ReceiptReused() public {
        _attest(M1);
        bytes memory r = _receipt("task-1", client);
        vm.prank(client);
        ac.rate(id, "task-1", 5, r);
        vm.prank(client);
        vm.expectRevert(AgentCred.ReceiptUsed.selector);
        ac.rate(id, "task-1", 5, r);
    }

    function test_RevertWhen_ReceiptStolenByOtherClient() public {
        _attest(M1);
        bytes memory r = _receipt("task-1", client);
        vm.prank(makeAddr("competidor"));
        vm.expectRevert(AgentCred.BadReceipt.selector);
        ac.rate(id, "task-1", 1, r);
    }

    function test_RevertWhen_SelfReviewWithoutReceipt() public {
        _attest(M1);
        bytes memory fake = _sign(0xBEEF, keccak256(abi.encode(ac.RECEIPT_TYPEHASH(), id, bytes32("t"), owner)));
        vm.prank(owner);
        vm.expectRevert(AgentCred.BadReceipt.selector);
        ac.rate(id, "t", 5, fake);
    }

    function test_NewMeasurementResetsReputation() public {
        _attest(M1);
        bytes memory r = _receipt("task-1", client);
        vm.prank(client);
        ac.rate(id, "task-1", 5, r);
        _attest(M1); // renovación con el mismo código: conserva
        (, uint256 n) = ac.reputation(id);
        assertEq(n, 1);
        _attest(M2); // código nuevo: resetea
        (, n) = ac.reputation(id);
        assertEq(n, 0);
    }

    function test_TransferInvalidatesAttestation() public {
        _attest(M1);
        address buyer = makeAddr("buyer");
        vm.prank(owner);
        ac.transferFrom(owner, buyer, id);
        assertFalse(ac.isTrusted(id));
    }

    function test_VerifyAgentSignature() public {
        _attest(M1);
        bytes32 digest = keccak256("respuesta del agente");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(enclavePk, digest);
        assertTrue(ac.verifyAgentSignature(id, digest, abi.encodePacked(r, s, v)));
        (v, r, s) = vm.sign(0xBEEF, digest);
        assertFalse(ac.verifyAgentSignature(id, digest, abi.encodePacked(r, s, v)));
    }

    function test_RevertWhen_BadScore() public {
        _attest(M1);
        bytes memory r = _receipt("t", client);
        vm.prank(client);
        vm.expectRevert(AgentCred.BadScore.selector);
        ac.rate(id, "t", 6, r);
    }
}
