// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleAirdrop} from "../src/MerkleAirdrop.sol";

/// @notice Construimos el árbol de Merkle EN el test (sin scripts externos)
///         usando el mismo hash de pares ordenados que MerkleProof de OZ.
contract MerkleAirdropTest is Test {
    MerkleAirdrop drop;
    uint256 constant N = 8;
    address[N] accounts;
    uint256[N] amounts;
    bytes32[] leaves;

    /// @dev Hash de un par ordenado (commutativo), igual que OZ.
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Raíz de un nivel de hojas (N potencia de 2 para simplificar).
    function _root(bytes32[] memory level) internal pure returns (bytes32) {
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i; i < next.length; i++) next[i] = _hashPair(level[2 * i], level[2 * i + 1]);
            level = next;
        }
        return level[0];
    }

    /// @dev Prueba para la hoja `idx`: el hermano en cada nivel.
    function _proof(bytes32[] memory level, uint256 idx) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](3); // log2(8)
        uint256 k;
        while (level.length > 1) {
            p[k++] = level[idx ^ 1]; // hermano: mismo par, otra posición
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i; i < next.length; i++) next[i] = _hashPair(level[2 * i], level[2 * i + 1]);
            level = next;
            idx /= 2;
        }
    }

    function setUp() public {
        // Instancia temporal solo para calcular hojas con la función pública.
        MerkleAirdrop tmp = new MerkleAirdrop(bytes32(0));
        for (uint256 i; i < N; i++) {
            accounts[i] = makeAddr(string.concat("user", vm.toString(i)));
            amounts[i] = (i + 1) * 100 ether;
            leaves.push(tmp.leaf(i, accounts[i], amounts[i]));
        }
        drop = new MerkleAirdrop(_root(leaves));
    }

    function test_ReclamoValido() public {
        bytes32[] memory p = _proof(leaves, 5);
        drop.claim(5, accounts[5], amounts[5], p);
        assertEq(drop.balanceOf(accounts[5]), 600 ether);
        assertTrue(drop.isClaimed(5));
    }

    function test_TodosReclaman() public {
        for (uint256 i; i < N; i++) {
            drop.claim(i, accounts[i], amounts[i], _proof(leaves, i));
        }
        assertEq(drop.totalSupply(), 3600 ether);
    }

    function test_RevertDobleReclamo() public {
        bytes32[] memory p = _proof(leaves, 0);
        drop.claim(0, accounts[0], amounts[0], p);
        vm.expectRevert(abi.encodeWithSelector(MerkleAirdrop.AlreadyClaimed.selector, 0));
        drop.claim(0, accounts[0], amounts[0], p);
    }

    function test_RevertMontoAlterado() public {
        bytes32[] memory p = _proof(leaves, 2);
        vm.expectRevert(MerkleAirdrop.InvalidProof.selector);
        drop.claim(2, accounts[2], amounts[2] * 10, p);
    }

    function test_RevertCuentaAjena() public {
        bytes32[] memory p = _proof(leaves, 3);
        vm.expectRevert(MerkleAirdrop.InvalidProof.selector);
        drop.claim(3, makeAddr("intruso"), amounts[3], p);
    }
}
