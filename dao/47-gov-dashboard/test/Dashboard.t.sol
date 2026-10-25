// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {GovToken} from "../src/GovToken.sol";
import {SimpleGovernor} from "../src/SimpleGovernor.sol";
import {GovernanceDashboard} from "../src/GovernanceDashboard.sol";

contract DashTest is Test {
    GovToken tok; SimpleGovernor gov; GovernanceDashboard dash;
    address alice;

    function setUp() public {
        tok = new GovToken();
        alice = address(this);
        tok.delegate(alice);
        vm.roll(block.number + 1);
        gov = new SimpleGovernor(address(tok));
        dash = new GovernanceDashboard(address(gov), address(tok));
    }

    function test_Dashboard() public {
        uint256 id = gov.propose(address(0xBEEF), "", "Mejora X");
        assertEq(dash.proposalCount(), 1);
        GovernanceDashboard.ProposalView memory v = dash.getProposal(id);
        assertEq(v.proposer, alice);
        assertEq(v.state, 0); // pending
        vm.roll(block.number + 1);
        gov.vote(id, true);
        v = dash.getProposal(id);
        assertEq(v.state, 1); // active
        assertEq(v.forVotes, tok.getPastVotes(alice, v.snapshot));
        assertTrue(dash.hasVoted(id, alice));
        (uint256 votes, address del) = dash.votingPower(alice);
        assertEq(votes, tok.balanceOf(alice));
        assertEq(del, alice);
    }
}
