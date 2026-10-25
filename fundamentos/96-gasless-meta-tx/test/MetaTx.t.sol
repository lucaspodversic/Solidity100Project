// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Forwarder} from "../src/Forwarder.sol";
import {GaslessToken} from "../src/GaslessToken.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

contract MetaTxTest is Test {
    Forwarder fwd;
    GaslessToken token;
    uint256 userPk = 0xA11CE;
    address user;
    address relayer = makeAddr("relayer");
    address bob = makeAddr("bob");

    bytes32 constant TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    function setUp() public {
        fwd = new Forwarder();
        token = new GaslessToken(address(fwd));
        user = vm.addr(userPk);
        token.transfer(user, 50 ether);
        vm.deal(relayer, 1 ether);
    }

    /// @dev Reproduce el separador de dominio EIP-712 del forwarder.
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("GaslessForwarder"),
                keccak256("1"),
                block.chainid,
                address(fwd)
            )
        );
    }

    /// @dev Arma y firma la request como lo haría la wallet del usuario.
    function _signed(uint256 pk, address from, bytes memory data, uint48 deadline)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory req)
    {
        bytes32 structHash = keccak256(
            abi.encode(TYPEHASH, from, address(token), 0, 100_000, fwd.nonces(from), deadline, keccak256(data))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        req = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: address(token),
            value: 0,
            gas: 100_000,
            deadline: deadline,
            data: data,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function test_TransferSinGas() public {
        ERC2771Forwarder.ForwardRequestData memory req =
            _signed(userPk, user, abi.encodeCall(token.transfer, (bob, 10 ether)), uint48(block.timestamp + 1 hours));
        assertTrue(fwd.verify(req));
        uint256 userEth = user.balance;
        vm.prank(relayer);
        fwd.execute(req);
        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.balanceOf(user), 40 ether);
        assertEq(user.balance, userEth); // el usuario no gastó ETH
    }

    function test_FaucetAtribuyeAlFirmante() public {
        ERC2771Forwarder.ForwardRequestData memory req =
            _signed(userPk, user, abi.encodeCall(token.faucet, ()), uint48(block.timestamp + 1 hours));
        vm.prank(relayer);
        fwd.execute(req);
        assertEq(token.balanceOf(user), 150 ether);
        assertEq(token.balanceOf(relayer), 0);
    }

    function test_NoReplay() public {
        ERC2771Forwarder.ForwardRequestData memory req =
            _signed(userPk, user, abi.encodeCall(token.transfer, (bob, 1 ether)), uint48(block.timestamp + 1 hours));
        vm.prank(relayer);
        fwd.execute(req);
        vm.prank(relayer);
        vm.expectRevert(); // nonce ya consumido => firma inválida
        fwd.execute(req);
    }

    function test_RevertDeadlineVencido() public {
        ERC2771Forwarder.ForwardRequestData memory req =
            _signed(userPk, user, abi.encodeCall(token.transfer, (bob, 1 ether)), uint48(block.timestamp + 10));
        vm.warp(block.timestamp + 11);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderExpiredRequest.selector, req.deadline));
        fwd.execute(req);
    }

    function test_RevertFirmaDeOtro() public {
        // Un atacante firma con su clave pero declara `from = user`.
        ERC2771Forwarder.ForwardRequestData memory req =
            _signed(0xBAD, user, abi.encodeCall(token.transfer, (bob, 1 ether)), uint48(block.timestamp + 1 hours));
        assertFalse(fwd.verify(req));
        vm.prank(relayer);
        vm.expectRevert();
        fwd.execute(req);
    }

    function test_LlamadaDirectaNormal() public {
        // Sin forwarder, _msgSender() == msg.sender.
        vm.prank(bob);
        token.faucet();
        assertEq(token.balanceOf(bob), 100 ether);
        assertTrue(token.isTrustedForwarder(address(fwd)));
    }
}
