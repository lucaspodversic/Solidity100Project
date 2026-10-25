// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {SimpleGovernor} from "./SimpleGovernor.sol";
import {GovToken} from "./GovToken.sol";

/// @title GovernanceDashboard — vistas de lectura para UI off-chain
/// @author Proyecto 47
/// @notice Agrega propuestas, votos y poder de voto en getters view.
///         Sin front obligatorio: cualquier UI (React/wagmi) consume estos métodos.
contract GovernanceDashboard {
    SimpleGovernor public immutable governor;
    GovToken public immutable token;

    struct ProposalView {
        uint256 id;
        address proposer;
        address target;
        uint64 startBlock;
        uint64 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        string description;
        uint256 snapshot;
        uint8 state; // 0=pending 1=active 2=succeeded 3=defeated 4=executed
    }

    constructor(address governor_, address token_) {
        governor = SimpleGovernor(governor_);
        token = GovToken(token_);
    }

    function proposalCount() external view returns (uint256) {
        return governor.nextId() - 1;
    }

    function getProposal(uint256 id) public view returns (ProposalView memory v) {
        (
            address proposer, address target, uint64 start, uint64 end,
            uint256 forV, uint256 againstV, bool executed, string memory desc
        ) = governor.proposalMeta(id);
        v = ProposalView({
            id: id, proposer: proposer, target: target,
            startBlock: start, endBlock: end,
            forVotes: forV, againstVotes: againstV,
            executed: executed, description: desc,
            snapshot: governor.snapshotOf(id),
            state: 0
        });
        v.state = _state(v);
    }

    function _state(ProposalView memory v) internal view returns (uint8) {
        if (v.executed) return 4;
        if (block.number < v.startBlock) return 0;
        if (block.number < v.endBlock) return 1;
        return v.forVotes > v.againstVotes ? 2 : 3;
    }

    function getProposals(uint256 fromId, uint256 toId) external view returns (ProposalView[] memory list) {
        require(toId >= fromId && fromId >= 1, "rango");
        list = new ProposalView[](toId - fromId + 1);
        for (uint256 i = fromId; i <= toId; ++i) list[i - fromId] = getProposal(i);
    }

    function votingPower(address account) external view returns (uint256 votes, address delegatee) {
        votes = token.getVotes(account);
        delegatee = token.delegates(account);
    }

    function hasVoted(uint256 id, address voter) external view returns (bool) {
        return governor.hasVoted(id, voter);
    }
}
