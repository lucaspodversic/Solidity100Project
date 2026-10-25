// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BasicDAO — votación sin token (1 address = 1 voto)
/// @author Proyecto 40
/// @notice El founder agrega miembros. Cualquier miembro propone. Tras el período de
///         votación, si hay mayoría simple de votos "sí" entre los que votaron y se
///         alcanzó el quorum, cualquiera puede ejecutar la llamada.
contract BasicDAO {
    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        uint64 start;
        uint64 end;
        uint32 yes;
        uint32 no;
        bool executed;
        string description;
    }

    address public immutable founder;
    uint256 public immutable votingPeriod; // segundos
    uint256 public immutable quorum;       // mínimo de votos totales
    mapping(address => bool) public isMember;
    uint256 public memberCount;
    uint256 public nextId = 1;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event MemberUpdated(address member, bool status);
    event Proposed(uint256 id, address proposer, string description);
    event Voted(uint256 id, address voter, bool support);
    event Executed(uint256 id);

    error NotMember(); error BadPeriod(); error AlreadyVoted(); error NotEnded();
    error Failed(); error AlreadyExec(); error Quorum(); error Rejected();

    constructor(uint256 votingPeriod_, uint256 quorum_) {
        founder = msg.sender;
        votingPeriod = votingPeriod_;
        quorum = quorum_;
        isMember[msg.sender] = true;
        memberCount = 1;
    }

    modifier onlyMember() {
        if (!isMember[msg.sender]) revert NotMember();
        _;
    }

    function setMember(address m, bool status) external {
        require(msg.sender == founder, "solo founder");
        if (isMember[m] == status) return;
        isMember[m] = status;
        status ? ++memberCount : --memberCount;
        emit MemberUpdated(m, status);
    }

    function propose(address target, uint256 value, bytes calldata data, string calldata desc)
        external onlyMember returns (uint256 id)
    {
        id = nextId++;
        Proposal storage p = proposals[id];
        p.proposer = msg.sender;
        p.target = target;
        p.value = value;
        p.data = data;
        p.start = uint64(block.timestamp);
        p.end = uint64(block.timestamp + votingPeriod);
        p.description = desc;
        emit Proposed(id, msg.sender, desc);
    }

    function vote(uint256 id, bool support) external onlyMember {
        Proposal storage p = proposals[id];
        if (block.timestamp < p.start || block.timestamp >= p.end) revert BadPeriod();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        hasVoted[id][msg.sender] = true;
        support ? ++p.yes : ++p.no;
        emit Voted(id, msg.sender, support);
    }

    function execute(uint256 id) external {
        Proposal storage p = proposals[id];
        if (block.timestamp < p.end) revert NotEnded();
        if (p.executed) revert AlreadyExec();
        if (uint256(p.yes) + p.no < quorum) revert Quorum();
        if (p.yes <= p.no) revert Rejected();
        p.executed = true;
        (bool ok,) = p.target.call{value: p.value}(p.data);
        if (!ok) revert Failed();
        emit Executed(id);
    }

    receive() external payable {}
}
