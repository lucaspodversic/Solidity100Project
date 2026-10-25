// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PaymentStream} from "../src/PaymentStream.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USD is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") { _mint(msg.sender, 1_000_000 ether); }
}

contract PaymentStreamTest is Test {
    PaymentStream ps;
    USD usd;
    address employer = address(this);
    address worker = makeAddr("worker");
    uint64 start;
    uint64 stop;
    uint256 id;

    function setUp() public {
        ps = new PaymentStream();
        usd = new USD();
        start = uint64(block.timestamp + 100);
        stop = start + 1000; // 1000 segundos
        usd.approve(address(ps), type(uint256).max);
        id = ps.createStream(worker, usd, 1000 ether, start, stop); // 1 mUSD/seg
    }

    function test_DevengadoLineal() public {
        assertEq(ps.withdrawable(id), 0);
        vm.warp(start + 250);
        assertEq(ps.withdrawable(id), 250 ether);
        assertEq(ps.ratePerSecond(id), 1 ether);
        vm.warp(stop + 999);
        assertEq(ps.withdrawable(id), 1000 ether);
    }

    function test_RetiroParcial() public {
        vm.warp(start + 400);
        vm.prank(worker);
        ps.withdraw(id, 300 ether);
        assertEq(usd.balanceOf(worker), 300 ether);
        assertEq(ps.withdrawable(id), 100 ether);
    }

    function test_RevertRetiroExcesivo() public {
        vm.warp(start + 10);
        vm.prank(worker);
        vm.expectRevert(PaymentStream.NothingToWithdraw.selector);
        ps.withdraw(id, 11 ether);
    }

    function test_CancelacionReparteJusto() public {
        vm.warp(start + 600);
        vm.prank(worker);
        ps.withdraw(id, 100 ether);
        uint256 before = usd.balanceOf(employer);
        ps.cancel(id);
        assertEq(usd.balanceOf(worker), 600 ether);
        assertEq(usd.balanceOf(employer), before + 400 ether);
        vm.expectRevert(abi.encodeWithSelector(PaymentStream.StreamNotFound.selector, id));
        ps.withdrawable(id);
    }

    function test_SoloPartesCancelan() public {
        vm.prank(makeAddr("x"));
        vm.expectRevert(PaymentStream.NotParty.selector);
        ps.cancel(id);
    }

    function test_ParamsInvalidos() public {
        vm.expectRevert(PaymentStream.InvalidParams.selector);
        ps.createStream(worker, usd, 1 ether, start, start);
    }

    /// @notice Invariante: devengado al receptor + resto al emisor == depósito, siempre.
    function testFuzz_ConservacionAlCancelar(uint32 dt) public {
        vm.warp(uint256(start) + bound(dt, 0, 2000));
        uint256 empBefore = usd.balanceOf(employer);
        ps.cancel(id);
        assertEq(usd.balanceOf(worker) + (usd.balanceOf(employer) - empBefore), 1000 ether);
        assertEq(usd.balanceOf(address(ps)), 0);
    }
}
