// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {PermitVaultVulnerable, PermitVaultSafe} from "../src/PermitVault.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract ReplayTest is Test {
    using MessageHashUtils for bytes32;

    PermitVaultVulnerable vul;
    PermitVaultSafe safe;
    uint256 pk = 0xA11CE;
    address user;

    function setUp() public {
        user = vm.addr(pk);
        vul = new PermitVaultVulnerable();
        safe = new PermitVaultSafe();
        vm.deal(user, 10 ether);
        vm.prank(user); vul.deposit{value: 2 ether}();
        vm.prank(user); safe.deposit{value: 2 ether}();
    }

    function test_ReplayVulnerable() public {
        bytes32 hash = keccak256(abi.encodePacked(user, uint256(1 ether))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        address relayer = makeAddr("relayer");
        vm.prank(relayer); vul.withdrawWithSig(user, 1 ether, sig);
        assertEq(relayer.balance, 1 ether);

        // REPLAY: misma firma otra vez
        address relayer2 = makeAddr("relayer2");
        vm.prank(relayer2); vul.withdrawWithSig(user, 1 ether, sig);
        assertEq(relayer2.balance, 1 ether);
        assertEq(vul.balances(user), 0);
    }

    function test_SafeBloqueaReplay() public {
        uint256 nonce = 0;
        bytes32 structHash = keccak256(abi.encode(safe.WITHDRAW_TYPEHASH(), user, uint256(1 ether), nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", safe.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        address relayer = makeAddr("relayer");
        vm.prank(relayer); safe.withdrawWithSig(user, 1 ether, nonce, sig);
        assertEq(relayer.balance, 1 ether);

        // replay con mismo nonce → revert
        vm.prank(relayer);
        vm.expectRevert(bytes("nonce"));
        safe.withdrawWithSig(user, 1 ether, nonce, sig);
    }

    function test_SafeDomainDistintoEnOtroContrato() public {
        PermitVaultSafe other = new PermitVaultSafe();
        vm.prank(user); other.deposit{value: 1 ether}();
        // Firma para `safe` no sirve en `other` (verifyingContract distinto)
        uint256 nonce = 0;
        bytes32 structHash = keccak256(abi.encode(safe.WITHDRAW_TYPEHASH(), user, uint256(1 ether), nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", safe.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.expectRevert(bytes("sig"));
        other.withdrawWithSig(user, 1 ether, nonce, sig);
    }
}
