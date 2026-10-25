// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AuditMarketplace} from "../src/AuditMarketplace.sol";
import {AuditCertificate} from "../src/AuditCertificate.sol";

/// @notice Contrato "auditado" de ejemplo.
contract Target {
    uint256 public x;

    function set(uint256 v) external {
        x = v;
    }
}

contract MarketTest is Test {
    AuditMarketplace m;
    AuditCertificate cert;
    Target target;
    address arbiter = makeAddr("arbiter");
    address client = makeAddr("client");
    address op1 = makeAddr("op1");
    address op2 = makeAddr("op2");
    uint256 a1;
    uint256 a2;
    bytes32 constant R1 = keccak256("informe agente 1");
    bytes32 constant R2 = keccak256("informe agente 2");

    function setUp() public {
        m = new AuditMarketplace(arbiter);
        cert = m.certificate();
        target = new Target();
        vm.deal(client, 100 ether);
        vm.deal(op1, 10 ether);
        vm.deal(op2, 10 ether);
        vm.prank(op1);
        a1 = m.registerAgent{value: 1.5 ether}(keccak256("gpt-auditor-v1"), "https://agent1");
        vm.prank(op2);
        a2 = m.registerAgent{value: 2 ether}(keccak256("llm-sec-v3"), "https://agent2");
    }

    function _job() internal returns (uint256 id) {
        vm.prank(client);
        id = m.postJob{value: 10 ether}(address(target), 1 days, 1 days, 2 days);
    }

    function _commitReveal(uint256 jobId, address op, uint256 agentId, bytes32 r) internal {
        bytes32 c = m.commitHash(jobId, agentId, r, "sal"); // cachear: un getter consumiría el prank
        vm.prank(op);
        m.commit(jobId, agentId, c);
    }

    function _reveal(uint256 jobId, address op, uint256 agentId, bytes32 r) internal {
        vm.prank(op);
        m.reveal(jobId, agentId, r, "sal");
    }

    function _fullRound() internal returns (uint256 jobId) {
        jobId = _job();
        _commitReveal(jobId, op1, a1, R1);
        _commitReveal(jobId, op2, a2, R2);
        vm.warp(block.timestamp + 1 days + 1);
        _reveal(jobId, op1, a1, R1);
        _reveal(jobId, op2, a2, R2);
        vm.warp(block.timestamp + 1 days);
    }

    function test_HappyPath_AwardAndCertificate() public {
        uint256 jobId = _fullRound();
        vm.prank(client);
        uint256 certId = m.award(jobId, a1);
        assertEq(m.credit(op1), 9.5 ether);
        assertEq(m.fees(), 0.5 ether);
        assertEq(cert.ownerOf(certId), client);
        assertTrue(cert.isValid(certId));
        assertTrue(cert.locked(certId));
        assertEq(m.reputation(a1), 1);
        (,,, bytes32 rh,,) = cert.certs(certId);
        assertEq(rh, R1);
        vm.prank(op1);
        m.claim();
        assertEq(op1.balance, 8.5 ether + 9.5 ether);
    }

    function test_RevertWhen_TransferCertificate() public {
        uint256 jobId = _fullRound();
        vm.prank(client);
        uint256 certId = m.award(jobId, a1);
        vm.prank(client);
        vm.expectRevert(AuditCertificate.Soulbound.selector);
        cert.transferFrom(client, op1, certId);
    }

    function test_SupportsERC5192() public view {
        assertTrue(cert.supportsInterface(0xb45a3c0e));
    }

    function test_RevertWhen_RevealWrongReport() public {
        uint256 jobId = _job();
        _commitReveal(jobId, op1, a1, R1);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(op1);
        vm.expectRevert(AuditMarketplace.BadReveal.selector);
        m.reveal(jobId, a1, R2, "sal"); // copia del informe de otro
    }

    function test_RevertWhen_CommitLate() public {
        uint256 jobId = _job();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(op1);
        vm.expectRevert(AuditMarketplace.WrongPhase.selector);
        m.commit(jobId, a1, bytes32(uint256(1)));
    }

    function test_RevertWhen_ClientCancelsAfterReveals() public {
        uint256 jobId = _fullRound();
        vm.prank(client);
        vm.expectRevert(AuditMarketplace.HasReveals.selector);
        m.cancel(jobId);
    }

    function test_CancelWithoutReveals() public {
        uint256 jobId = _job();
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(client);
        m.cancel(jobId);
        assertEq(m.credit(client), 10 ether);
    }

    function test_SplitWhenClientIgnores() public {
        uint256 jobId = _fullRound();
        vm.warp(block.timestamp + 2 days + 1);
        m.settleExpired(jobId);
        assertEq(m.credit(op1), 4.75 ether);
        assertEq(m.credit(op2), 4.75 ether);
        vm.prank(client);
        vm.expectRevert(AuditMarketplace.WrongPhase.selector);
        m.award(jobId, a1);
    }

    function test_CertificateInvalidWhenCodeChanges() public {
        uint256 jobId = _fullRound();
        vm.prank(client);
        uint256 certId = m.award(jobId, a1);
        vm.etch(address(target), hex"6001600055"); // "actualización" del código
        assertFalse(cert.isValid(certId));
    }

    function test_RevokeAndSlash() public {
        uint256 jobId = _fullRound();
        vm.prank(client);
        uint256 certId = m.award(jobId, a1);
        vm.prank(arbiter);
        m.revokeAndSlash(certId, "reentrancy no detectada");
        assertFalse(cert.isValid(certId));
        assertEq(m.credit(client), 0.75 ether);
        (,,, uint256 stake,,,) = m.agents(a1);
        assertEq(stake, 0.75 ether);
        assertEq(m.reputation(a1), 0);
        // con stake < MIN_STAKE ya no puede competir
        uint256 j2 = _job();
        vm.prank(op1);
        vm.expectRevert(AuditMarketplace.LowStake.selector);
        m.commit(j2, a1, bytes32(uint256(1)));
    }

    function test_RevertWhen_NonArbiterSlashes() public {
        vm.prank(client);
        vm.expectRevert();
        m.revokeAndSlash(1, "x");
    }

    function test_UnbondFlow() public {
        vm.prank(op1);
        m.startUnbond(a1);
        uint256 jobId = _job();
        vm.prank(op1);
        vm.expectRevert(AuditMarketplace.Unbonding.selector);
        m.commit(jobId, a1, bytes32(uint256(1)));
        vm.prank(op1);
        vm.expectRevert(AuditMarketplace.NotUnbonding.selector);
        m.withdrawStake(a1);
        vm.warp(block.timestamp + 14 days);
        vm.prank(op1);
        m.withdrawStake(a1);
        assertEq(m.credit(op1), 1.5 ether);
    }

    function test_RevertWhen_PostJobForEOA() public {
        vm.prank(client);
        vm.expectRevert(AuditMarketplace.NoTarget.selector);
        m.postJob{value: 1 ether}(makeAddr("eoa"), 1, 1, 1);
    }
}
