// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Groth16Verifier} from "../src/Groth16Verifier.sol";
import {ZkVoting, IGroth16Verifier} from "../src/ZkVoting.sol";

/// @title Tests del verificador Groth16 REAL (precompilados BN254) y de la votación
/// @notice Para no depender de circom/snarkjs usamos un **trusted setup de juguete**
///         cuyo "trapdoor" conocemos: todos los puntos son múltiplos escalares de los
///         generadores. Con β = γ = δ = B = G2 (generador), la ecuación de Groth16
///             e(A,B) = e(α,β)·e(vk_x,γ)·e(C,δ)
///         se reduce en los exponentes a  a = α + vk_x + c  (mod R).
///         Elegimos `a` y despejamos `c`, así obtenemos una prueba que el verificador
///         acepta pasando por los pairings reales. Esto valida la lógica de verificación
///         (vk_x, negación, codificación de G2, pairing). **Es inseguro a propósito**:
///         quien conoce el trapdoor puede falsificar pruebas; en producción la VK sale
///         de una ceremonia (Powers of Tau + fase 2).
contract ZkVotingTest is Test {
    uint256 constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // Generador de G2 (EIP-197: [x_im, x_re], [y_im, y_re])
    uint256 constant G2X1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant G2X0 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant G2Y1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant G2Y0 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;

    // Trapdoor de juguete
    uint256 constant ALPHA = 7;
    uint256[5] IC = [uint256(11), 13, 17, 19, 23];

    Groth16Verifier verifier;
    ZkVoting voting;
    address registrar = makeAddr("registrar");
    uint256 constant ROOT = 0x1234567890abcdef;

    struct Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    function _g1mul(uint256 s) internal view returns (Groth16Verifier.G1 memory p) {
        uint256[3] memory inp = [uint256(1), 2, s];
        uint256[2] memory out;
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x07, inp, 0x60, out, 0x40)
        }
        require(ok, "ecMul");
        p = Groth16Verifier.G1(out[0], out[1]);
    }

    function _g2() internal pure returns (Groth16Verifier.G2 memory g) {
        g.x = [G2X1, G2X0];
        g.y = [G2Y1, G2Y0];
    }

    function setUp() public {
        Groth16Verifier.G1[] memory ic = new Groth16Verifier.G1[](5);
        for (uint256 i = 0; i < 5; i++) ic[i] = _g1mul(IC[i]);
        verifier = new Groth16Verifier(_g1mul(ALPHA), _g2(), _g2(), _g2(), ic);
        voting = new ZkVoting(IGroth16Verifier(address(verifier)), registrar);
        vm.startPrank(registrar);
        voting.setRoot(ROOT);
        voting.createProposal(keccak256("Propuesta 1"), uint64(block.timestamp), uint64(block.timestamp + 7 days), 3);
        vm.stopPrank();
    }

    /// "Prover" de juguete: genera una prueba válida para los inputs dados.
    function _prove(uint256[4] memory inp, uint256 aScalar) internal view returns (Proof memory pr) {
        uint256 vkx = IC[0];
        for (uint256 i = 0; i < 4; i++) vkx = addmod(vkx, mulmod(inp[i] % R, IC[i + 1], R), R);
        uint256 cS = addmod(aScalar, R - addmod(ALPHA, vkx, R), R);
        Groth16Verifier.G1 memory A = _g1mul(aScalar);
        Groth16Verifier.G1 memory C = _g1mul(cS);
        pr.a = [A.x, A.y];
        pr.b = [[G2X1, G2X0], [G2Y1, G2Y0]];
        pr.c = [C.x, C.y];
    }

    function _inputs(uint256 nul, uint256 pid, uint256 opt) internal pure returns (uint256[4] memory) {
        return [ROOT, nul, pid, opt];
    }

    // ------------------- verificador -------------------

    function test_VerifierAcceptsValidProof() public view {
        uint256[4] memory i4 = _inputs(111, 1, 2);
        Proof memory pr = _prove(i4, 98765);
        uint256[] memory inp = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) inp[i] = i4[i];
        assertTrue(verifier.verifyProof(pr.a, pr.b, pr.c, inp));
    }

    function test_VerifierRejectsTamperedInput() public view {
        uint256[4] memory i4 = _inputs(111, 1, 2);
        Proof memory pr = _prove(i4, 98765);
        uint256[] memory inp = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) inp[i] = i4[i];
        inp[3] = 1; // cambio el voto
        assertFalse(verifier.verifyProof(pr.a, pr.b, pr.c, inp));
    }

    function test_VerifierRejectsTamperedProof() public view {
        uint256[4] memory i4 = _inputs(111, 1, 2);
        Proof memory pr = _prove(i4, 98765);
        Groth16Verifier.G1 memory other = _g1mul(5);
        pr.c = [other.x, other.y];
        uint256[] memory inp = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) inp[i] = i4[i];
        assertFalse(verifier.verifyProof(pr.a, pr.b, pr.c, inp));
    }

    function test_VerifierRejectsPointNotOnCurve() public view {
        uint256[4] memory i4 = _inputs(111, 1, 2);
        Proof memory pr = _prove(i4, 98765);
        pr.a = [uint256(1), 3]; // (1,3) no está en y² = x³ + 3
        uint256[] memory inp = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) inp[i] = i4[i];
        assertFalse(verifier.verifyProof(pr.a, pr.b, pr.c, inp));
    }

    function test_RevertWhen_InputNotInField() public {
        uint256[] memory inp = new uint256[](4);
        inp[0] = R; // maleabilidad: R ≡ 0
        Proof memory pr;
        vm.expectRevert(Groth16Verifier.InputNotInField.selector);
        verifier.verifyProof(pr.a, pr.b, pr.c, inp);
    }

    function test_RevertWhen_WrongInputLength() public {
        uint256[] memory inp = new uint256[](3);
        Proof memory pr;
        vm.expectRevert(Groth16Verifier.WrongInputLength.selector);
        verifier.verifyProof(pr.a, pr.b, pr.c, inp);
    }

    function testFuzz_ValidProofs(uint256 nul, uint256 a, uint8 opt) public view {
        nul = bound(nul, 0, R - 1);
        a = bound(a, 1, R - 1);
        uint256[4] memory i4 = _inputs(nul, 1, opt % 3);
        Proof memory pr = _prove(i4, a);
        uint256[] memory inp = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) inp[i] = i4[i];
        assertTrue(verifier.verifyProof(pr.a, pr.b, pr.c, inp));
    }

    // ------------------- votación -------------------

    function test_VoteCounts() public {
        Proof memory p1 = _prove(_inputs(111, 1, 2), 1001);
        Proof memory p2 = _prove(_inputs(222, 1, 0), 2002);
        // cualquiera (un relayer) puede enviar el voto
        vm.prank(makeAddr("relayer"));
        voting.vote(1, 2, 111, p1.a, p1.b, p1.c);
        voting.vote(1, 0, 222, p2.a, p2.b, p2.c);
        uint256[] memory r = voting.results(1);
        assertEq(r[0], 1);
        assertEq(r[1], 0);
        assertEq(r[2], 1);
        assertTrue(voting.nullifierUsed(111));
    }

    function test_RevertWhen_DoubleVote() public {
        Proof memory p1 = _prove(_inputs(111, 1, 2), 1001);
        voting.vote(1, 2, 111, p1.a, p1.b, p1.c);
        // misma persona (mismo nullifier) con otra opción
        Proof memory p2 = _prove(_inputs(111, 1, 1), 3003);
        vm.expectRevert(ZkVoting.NullifierAlreadyUsed.selector);
        voting.vote(1, 1, 111, p2.a, p2.b, p2.c);
    }

    function test_RevertWhen_ChangingOptionOfSomeoneElsesProof() public {
        Proof memory p1 = _prove(_inputs(111, 1, 2), 1001);
        // un relayer malicioso intenta cambiar el voto
        vm.expectRevert(ZkVoting.InvalidProof.selector);
        voting.vote(1, 0, 111, p1.a, p1.b, p1.c);
    }

    function test_RevertWhen_ProofForOtherProposal() public {
        vm.prank(registrar);
        voting.createProposal(keccak256("P2"), uint64(block.timestamp), uint64(block.timestamp + 1 days), 2);
        Proof memory p1 = _prove(_inputs(111, 1, 1), 1001);
        vm.expectRevert(ZkVoting.InvalidProof.selector);
        voting.vote(2, 1, 111, p1.a, p1.b, p1.c);
    }

    function test_RootSnapshot() public {
        // nueva raíz (se sumaron votantes) => las propuestas viejas siguen con la raíz original
        vm.prank(registrar);
        voting.setRoot(999);
        Proof memory p1 = _prove(_inputs(111, 1, 2), 1001); // con ROOT viejo
        voting.vote(1, 2, 111, p1.a, p1.b, p1.c);
        assertEq(voting.results(1)[2], 1);
    }

    function test_RevertWhen_Closed() public {
        Proof memory p1 = _prove(_inputs(111, 1, 2), 1001);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(ZkVoting.VotingClosed.selector);
        voting.vote(1, 2, 111, p1.a, p1.b, p1.c);
    }

    function test_RevertWhen_InvalidOption() public {
        Proof memory p1 = _prove(_inputs(111, 1, 5), 1001);
        vm.expectRevert(ZkVoting.InvalidOption.selector);
        voting.vote(1, 5, 111, p1.a, p1.b, p1.c);
    }

    function test_RevertWhen_NotRegistrar() public {
        vm.expectRevert();
        voting.setRoot(1);
    }
}
