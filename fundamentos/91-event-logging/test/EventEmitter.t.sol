// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {TaskBoard} from "../src/EventEmitter.sol";

contract EventEmitterTest is Test {
    TaskBoard b;
    address alice = makeAddr("alice");

    // Redeclaramos los eventos para usarlos con vm.expectEmit.
    event TaskCreated(uint256 indexed id, address indexed owner, string title);
    event TaskStatusChanged(uint256 indexed id, address indexed owner, TaskBoard.Status indexed newStatus);

    function setUp() public {
        b = new TaskBoard();
    }

    function test_ExpectEmitCreate() public {
        // (chequear topic1, topic2, topic3, data)
        vm.expectEmit(true, true, false, true, address(b));
        emit TaskCreated(1, alice, "Comprar pan");
        vm.prank(alice);
        b.create("Comprar pan");
    }

    function test_ExpectEmitStatus() public {
        vm.startPrank(alice);
        uint256 id = b.create("x");
        vm.expectEmit(true, true, true, false, address(b));
        emit TaskStatusChanged(id, alice, TaskBoard.Status.Done);
        b.complete(id);
        vm.stopPrank();
    }

    /// @notice Inspección cruda de topics/data, igual que haría un indexador.
    function test_EstructuraDelLog() public {
        vm.recordLogs();
        vm.prank(alice);
        b.create("Leer logs");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("TaskCreated(uint256,address,string)"));
        assertEq(uint256(logs[0].topics[1]), 1);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), alice);
        assertEq(abi.decode(logs[0].data, (string)), "Leer logs");
    }

    function test_EventoAnonimoSinTopic0() public {
        vm.recordLogs();
        b.ping();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics.length, 1); // solo el `from` indexado
        assertEq(address(uint160(uint256(logs[0].topics[0]))), address(this));
    }

    function test_SoloDuenoCambiaEstado() public {
        vm.prank(alice);
        uint256 id = b.create("x");
        vm.expectRevert(TaskBoard.NotTaskOwner.selector);
        b.cancel(id);
        vm.expectRevert(TaskBoard.InvalidTask.selector);
        b.cancel(99);
    }
}
