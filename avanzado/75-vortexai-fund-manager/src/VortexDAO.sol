// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VortexVault} from "./VortexVault.sol";

/// @title VortexDAO — Gobierno del fondo por los holders de VTX
/// @notice Las propuestas son llamadas al vault (`setParams`, `setAgent`, `unpause`). Flujo:
///         propose → votación de 3 días (snapshot) → quórum 10% y mayoría → timelock de 1 día → execute.
contract VortexDAO {
    struct Proposal {
        bytes data; // calldata para el vault
        uint256 snapshot;
        uint64 voteEnd;
        uint64 eta;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
    }

    uint256 public constant VOTING = 3 days;
    uint256 public constant TIMELOCK = 1 days;
    uint256 public constant QUORUM_BPS = 1_000;

    VortexVault public vault;
    address private immutable deployer;
    Proposal[] internal proposals;
    mapping(uint256 => mapping(address => bool)) public voted;

    event Proposed(uint256 indexed id, address proposer, bytes4 selector);
    event Voted(uint256 indexed id, address voter, bool support, uint256 weight);
    event Executed(uint256 indexed id);

    error AlreadyInit();
    error NoVotes();
    error Closed();
    error AlreadyVoted();
    error NotPassed();
    error TooEarly();
    error Done();
    error BadSelector();
    error CallFailed();

    constructor() {
        deployer = msg.sender;
    }

    function init(VortexVault v) external {
        if (msg.sender != deployer || address(vault) != address(0)) revert AlreadyInit();
        vault = v;
    }

    function propose(bytes calldata data) external returns (uint256 id) {
        bytes4 sel = bytes4(data[:4]);
        // solo funciones de gobierno: la DAO no puede, p. ej., mover fondos arbitrariamente
        if (sel != VortexVault.setParams.selector && sel != VortexVault.setAgent.selector && sel != VortexVault.unpause.selector)
        {
            revert BadSelector();
        }
        uint256 snap = block.number - 1;
        if (vault.getPastVotes(msg.sender, snap) == 0) revert NoVotes();
        id = proposals.length;
        proposals.push(Proposal(data, snap, uint64(block.timestamp + VOTING), 0, 0, 0, false));
        emit Proposed(id, msg.sender, sel);
    }

    function vote(uint256 id, bool support) external {
        Proposal storage p = proposals[id];
        if (block.timestamp > p.voteEnd) revert Closed();
        if (voted[id][msg.sender]) revert AlreadyVoted();
        uint256 w = vault.getPastVotes(msg.sender, p.snapshot);
        if (w == 0) revert NoVotes();
        voted[id][msg.sender] = true;
        if (support) p.forVotes += w;
        else p.againstVotes += w;
        emit Voted(id, msg.sender, support, w);
    }

    function queue(uint256 id) external {
        Proposal storage p = proposals[id];
        if (block.timestamp <= p.voteEnd || p.eta != 0) revert NotPassed();
        uint256 supply = vault.getPastTotalSupply(p.snapshot);
        if ((p.forVotes + p.againstVotes) * 10_000 < supply * QUORUM_BPS || p.forVotes <= p.againstVotes) {
            revert NotPassed();
        }
        p.eta = uint64(block.timestamp + TIMELOCK);
    }

    function execute(uint256 id) external {
        Proposal storage p = proposals[id];
        if (p.eta == 0 || block.timestamp < p.eta) revert TooEarly();
        if (p.executed) revert Done();
        p.executed = true;
        (bool ok,) = address(vault).call(p.data);
        if (!ok) revert CallFailed();
        emit Executed(id);
    }
}
