// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {BasicDAO} from "../src/BasicDAO.sol";

contract Target {
    uint256 public x;
    function set(uint256 v) external { x = v; }
}

contract BasicDAOTest is Test {
    BasicDAO dao;
    Target t;
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");

    function setUp() public {
        dao = new BasicDAO(1 days, 2);
        t = new Target();
        dao.setMember(a, true);
        dao.setMember(b, true);
        dao.setMember(c, true);
    }

    function test_FlujoCompleto() public {
        vm.prank(a);
        uint256 id = dao.propose(address(t), 0, abi.encodeWithSelector(Target.set.selector, 42), "set 42");
        vm.prank(a); dao.vote(id, true);
        vm.prank(b); dao.vote(id, true);
        vm.prank(c); dao.vote(id, false);
        vm.warp(block.timestamp + 1 days);
        dao.execute(id);
        assertEq(t.x(), 42);
    }

    function test_QuorumInsuficiente() public {
        vm.prank(a);
        uint256 id = dao.propose(address(t), 0, abi.encodeWithSelector(Target.set.selector, 1), "x");
        vm.prank(a); dao.vote(id, true);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(BasicDAO.Quorum.selector);
        dao.execute(id);
    }

    function test_DobleVoto() public {
        vm.prank(a);
        uint256 id = dao.propose(address(t), 0, "", "x");
        vm.prank(a); dao.vote(id, true);
        vm.prank(a);
        vm.expectRevert(BasicDAO.AlreadyVoted.selector);
        dao.vote(id, true);
    }
}
