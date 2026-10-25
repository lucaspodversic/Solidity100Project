// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title Governor — gobernanza on-chain con ERC20Votes + snapshot por bloque
/// @author Proyecto 41
/// @notice El clock de OpenZeppelin Votes es `block.number` (ERC-6372).
///         Guardamos el bloque de la propuesta como snapshot y consultamos
///         `getPastVotes` recién cuando `block.number > snapshot`.
contract Governor {
    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        uint64 startBlock;
        uint64 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        string description;
    }

    IVotes public immutable token;
    uint256 public immutable votingDelay;   // en bloques
    uint256 public immutable votingPeriod;  // en bloques
    uint256 public immutable proposalThreshold;
    uint256 public immutable quorumVotes;

    uint256 public nextId = 1;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => uint256) public snapshotOf;

    event Proposed(uint256 id, address proposer);
    event Voted(uint256 id, address voter, bool support, uint256 weight);
    event Executed(uint256 id);

    error Threshold(); error Already(); error BadWindow(); error NoPower();
    error Quorum(); error Defeated(); error ExecFail();

    constructor(
        address token_, uint256 delay_, uint256 period_, uint256 threshold_, uint256 quorum_
    ) {
        token = IVotes(token_);
        votingDelay = delay_;
        votingPeriod = period_;
        proposalThreshold = threshold_;
        quorumVotes = quorum_;
    }

    function propose(address target, uint256 value, bytes calldata data, string calldata desc)
        external returns (uint256 id)
    {
        if (token.getVotes(msg.sender) < proposalThreshold) revert Threshold();
        id = nextId++;
        uint64 start = uint64(block.number + votingDelay);
        Proposal storage p = proposals[id];
        p.proposer = msg.sender;
        p.target = target;
        p.value = value;
        p.data = data;
        p.startBlock = start;
        p.endBlock = uint64(uint256(start) + votingPeriod);
        p.description = desc;
        snapshotOf[id] = block.number;
        emit Proposed(id, msg.sender);
    }

    function vote(uint256 id, bool support) external {
        Proposal storage p = proposals[id];
        if (block.number < p.startBlock || block.number >= p.endBlock) revert BadWindow();
        if (hasVoted[id][msg.sender]) revert Already();
        uint256 weight = token.getPastVotes(msg.sender, snapshotOf[id]);
        if (weight == 0) revert NoPower();
        hasVoted[id][msg.sender] = true;
        if (support) p.forVotes += weight;
        else p.againstVotes += weight;
        emit Voted(id, msg.sender, support, weight);
    }

    function execute(uint256 id) external {
        Proposal storage p = proposals[id];
        if (block.number < p.endBlock) revert BadWindow();
        if (p.executed) revert Already();
        if (p.forVotes < quorumVotes) revert Quorum();
        if (p.forVotes <= p.againstVotes) revert Defeated();
        p.executed = true;
        (bool ok,) = p.target.call{value: p.value}(p.data);
        if (!ok) revert ExecFail();
        emit Executed(id);
    }

    receive() external payable {}
}
