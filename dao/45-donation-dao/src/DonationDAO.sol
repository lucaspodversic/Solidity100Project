// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DonationDAO — donantes votan la priorización de proyectos
/// @author Proyecto 45
/// @notice El peso de voto = ETH donado acumulado. Los proyectos se proponen y
///         los donantes asignan su peso. El admin (o cualquiera tras deadline)
///         desembolsa al proyecto ganador.
contract DonationDAO is ReentrancyGuard {
    struct Project {
        address payable recipient;
        string name;
        uint256 votes;
        bool paid;
    }

    address public immutable admin;
    uint256 public immutable votingDeadline;
    mapping(address => uint256) public donated;
    mapping(address => mapping(uint256 => uint256)) public allocated; // donor => project => weight
    mapping(address => uint256) public remainingWeight;
    Project[] public projects;
    bool public finalized;
    uint256 public winnerId;

    event Donated(address donor, uint256 amount);
    event ProjectAdded(uint256 id, address recipient, string name);
    event Allocated(address donor, uint256 projectId, uint256 weight);
    event Finalized(uint256 winnerId, uint256 amount);

    error Closed(); error Bad(); error NoWeight();

    constructor(uint256 duration) {
        admin = msg.sender;
        votingDeadline = block.timestamp + duration;
    }

    function donate() external payable {
        if (block.timestamp >= votingDeadline) revert Closed();
        if (msg.value == 0) revert Bad();
        donated[msg.sender] += msg.value;
        remainingWeight[msg.sender] += msg.value;
        emit Donated(msg.sender, msg.value);
    }

    function addProject(address payable recipient, string calldata name) external {
        require(msg.sender == admin, "admin");
        projects.push(Project(recipient, name, 0, false));
        emit ProjectAdded(projects.length - 1, recipient, name);
    }

    function allocate(uint256 projectId, uint256 weight) external {
        if (block.timestamp >= votingDeadline) revert Closed();
        if (projectId >= projects.length) revert Bad();
        if (weight > remainingWeight[msg.sender]) revert NoWeight();
        remainingWeight[msg.sender] -= weight;
        allocated[msg.sender][projectId] += weight;
        projects[projectId].votes += weight;
        emit Allocated(msg.sender, projectId, weight);
    }

    function finalize() external nonReentrant {
        if (block.timestamp < votingDeadline) revert Closed();
        require(!finalized, "done");
        finalized = true;
        uint256 best;
        uint256 bestVotes;
        for (uint i; i < projects.length; ++i) {
            if (projects[i].votes > bestVotes) { bestVotes = projects[i].votes; best = i; }
        }
        winnerId = best;
        projects[best].paid = true;
        uint256 bal = address(this).balance;
        (bool ok,) = projects[best].recipient.call{value: bal}("");
        require(ok, "pay");
        emit Finalized(best, bal);
    }

    function projectCount() external view returns (uint256) { return projects.length; }
}
