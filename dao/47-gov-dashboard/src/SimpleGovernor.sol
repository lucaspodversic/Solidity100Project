// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title SimpleGovernor — governor mínimo para alimentar el dashboard
contract SimpleGovernor {
    struct Proposal {
        address proposer;
        address target;
        bytes data;
        uint64 startBlock;
        uint64 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        string description;
    }
    IVotes public immutable token;
    uint256 public nextId = 1;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => uint256) public snapshotOf;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    constructor(address token_) { token = IVotes(token_); }

    function propose(address target, bytes calldata data, string calldata desc) external returns (uint256 id) {
        require(token.getVotes(msg.sender) > 0, "sin votos");
        id = nextId++;
        Proposal storage p = proposals[id];
        p.proposer = msg.sender;
        p.target = target;
        p.data = data;
        p.startBlock = uint64(block.number + 1);
        p.endBlock = uint64(block.number + 11);
        p.description = desc;
        snapshotOf[id] = block.number;
    }

    function vote(uint256 id, bool support) external {
        Proposal storage p = proposals[id];
        require(block.number >= p.startBlock && block.number < p.endBlock, "ventana");
        require(!hasVoted[id][msg.sender], "ya");
        uint256 w = token.getPastVotes(msg.sender, snapshotOf[id]);
        require(w > 0, "0");
        hasVoted[id][msg.sender] = true;
        support ? (p.forVotes += w) : (p.againstVotes += w);
    }

    /// @notice Lectura limpia para el dashboard (evita el getter auto con `bytes`).
    function proposalMeta(uint256 id) external view returns (
        address proposer, address target, uint64 startBlock, uint64 endBlock,
        uint256 forVotes, uint256 againstVotes, bool executed, string memory description
    ) {
        Proposal storage p = proposals[id];
        return (p.proposer, p.target, p.startBlock, p.endBlock, p.forVotes, p.againstVotes, p.executed, p.description);
    }
}
