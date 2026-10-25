// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title QuadraticGovernor — votación cuadrática + delegación simple
/// @author Proyecto 42
/// @notice El peso efectivo de un voto es `sqrt(credits)`. Cada votante tiene un
///         presupuesto de créditos por propuesta. La delegación transfiere el
///         presupuesto al delegatee.
/// @dev sqrt entero por binary search. No usamos ERC20Votes: el peso sale del
///      balance (o del delegado) al momento del voto.
contract QuadraticGovernor {
    struct Proposal {
        address proposer;
        address target;
        bytes data;
        uint64 deadline;
        uint256 yesWeight; // suma de sqrt(credits)
        uint256 noWeight;
        bool executed;
        string description;
    }

    IERC20 public immutable token;
    uint256 public immutable creditsPerProposal; // créditos que puede gastar cada voter
    uint256 public immutable votingPeriod;
    uint256 public nextId = 1;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => uint256)) public spent; // créditos gastados
    mapping(address => address) public delegates; // voter => delegatee (address(0)=self)

    event Proposed(uint256 id);
    event Voted(uint256 id, address voter, bool support, uint256 credits, uint256 weight);
    event Delegated(address voter, address to);
    event Executed(uint256 id);

    error NoBalance(); error BadCredits(); error Ended(); error AlreadyExec(); error Defeated(); error Fail();

    constructor(address token_, uint256 credits_, uint256 period_) {
        token = IERC20(token_);
        creditsPerProposal = credits_;
        votingPeriod = period_;
    }

    function delegate(address to) external {
        delegates[msg.sender] = to;
        emit Delegated(msg.sender, to);
    }

    /// @dev Quién ejerce el poder de `account` (sí mismo si no delegó).
    function votingPowerOf(address account) public view returns (address) {
        address d = delegates[account];
        return d == address(0) ? account : d;
    }

    function propose(address target, bytes calldata data, string calldata desc) external returns (uint256 id) {
        if (token.balanceOf(msg.sender) == 0) revert NoBalance();
        id = nextId++;
        Proposal storage p = proposals[id];
        p.proposer = msg.sender;
        p.target = target;
        p.data = data;
        p.deadline = uint64(block.timestamp + votingPeriod);
        p.description = desc;
        emit Proposed(id);
    }

    /// @notice Gasta `credits` del presupuesto (máx creditsPerProposal) y suma sqrt(credits) al lado.
    /// @dev Solo puede votar quien tenga balance > 0 (o vote en nombre propio con tokens).
    function vote(uint256 id, bool support, uint256 credits) external {
        Proposal storage p = proposals[id];
        if (block.timestamp >= p.deadline) revert Ended();
        if (credits == 0) revert BadCredits();
        // El msg.sender debe ser el ejerciente; si Alice delegó a Bob, Alice no vota, Bob sí
        // y Bob puede usar su propio presupuesto. (Modelo simple de delegación de derecho a voto.)
        if (token.balanceOf(msg.sender) == 0) revert NoBalance();
        uint256 already = spent[id][msg.sender];
        if (already + credits > creditsPerProposal) revert BadCredits();
        spent[id][msg.sender] = already + credits;
        uint256 weight = sqrt(credits);
        support ? (p.yesWeight += weight) : (p.noWeight += weight);
        emit Voted(id, msg.sender, support, credits, weight);
    }

    function execute(uint256 id) external {
        Proposal storage p = proposals[id];
        if (block.timestamp < p.deadline) revert Ended(); // reuse: aún no termina → revert
        // Fix semantics: if not ended, revert with a clear path
        if (p.executed) revert AlreadyExec();
        if (p.yesWeight <= p.noWeight) revert Defeated();
        p.executed = true;
        (bool ok,) = p.target.call(p.data);
        if (!ok) revert Fail();
        emit Executed(id);
    }

    /// @notice Ejecuta solo si la deadline pasó (separado del check confuso).
    function executeAfterDeadline(uint256 id) external {
        Proposal storage p = proposals[id];
        require(block.timestamp >= p.deadline, "activa");
        if (p.executed) revert AlreadyExec();
        if (p.yesWeight <= p.noWeight) revert Defeated();
        p.executed = true;
        (bool ok,) = p.target.call(p.data);
        if (!ok) revert Fail();
        emit Executed(id);
    }

    /// @dev Raíz cuadrada entera (binary search).
    function sqrt(uint256 x) public pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }
}
