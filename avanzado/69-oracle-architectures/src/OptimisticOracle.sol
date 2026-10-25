// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOracle} from "./IOracle.sol";

/// @title OptimisticOracle — Arquitectura 3: "asumir verdadero salvo disputa" (estilo UMA)
/// @notice Un **proponente** afirma un valor depositando un `BOND`. Durante `LIVENESS`
///         cualquiera puede **disputar** depositando el mismo bond. Si nadie disputa, el
///         valor se acepta y el proponente recupera su bond. Si hay disputa, un
///         **árbitro** (en UMA, el DVM: votación de holders de UMA) decide: el ganador se
///         lleva ambos bonds (menos un fee de arbitraje).
/// @dev Seguridad: alcanza con **un solo observador honesto** que dispute. El costo es la
///      latencia (liveness) y la confianza final en el árbitro.
contract OptimisticOracle is IOracle, ReentrancyGuard {
    enum State {
        None,
        Proposed,
        Disputed,
        Settled
    }

    struct Assertion {
        address proposer;
        address disputer;
        uint256 value;
        uint64 proposedAt;
        State state;
    }

    uint256 public constant BOND = 1 ether;
    uint256 public constant LIVENESS = 2 hours;
    uint256 public constant ARBITRATION_FEE_BPS = 1_000; // 10% del bond perdedor
    address public immutable arbitrator;

    Assertion[] public assertions;
    uint256 public lastValue;
    uint256 public lastUpdated;
    uint256 public feesCollected;
    mapping(address => uint256) public payouts;

    event Proposed(uint256 indexed id, address indexed proposer, uint256 value);
    event Disputed(uint256 indexed id, address indexed disputer);
    event Settled(uint256 indexed id, uint256 value, bool disputed, bool proposerWon);

    error WrongBond();
    error BadState();
    error LivenessNotOver();
    error LivenessOver();
    error NotArbitrator();
    error NoData();

    constructor(address _arbitrator) {
        arbitrator = _arbitrator;
    }

    /// @notice Propone un valor con bond.
    function propose(uint256 value) external payable returns (uint256 id) {
        if (msg.value != BOND) revert WrongBond();
        id = assertions.length;
        assertions.push(Assertion(msg.sender, address(0), value, uint64(block.timestamp), State.Proposed));
        emit Proposed(id, msg.sender, value);
    }

    /// @notice Disputa una propuesta dentro del liveness con el mismo bond.
    function dispute(uint256 id) external payable {
        Assertion storage a = assertions[id];
        if (a.state != State.Proposed) revert BadState();
        if (block.timestamp >= a.proposedAt + LIVENESS) revert LivenessOver();
        if (msg.value != BOND) revert WrongBond();
        a.disputer = msg.sender;
        a.state = State.Disputed;
        emit Disputed(id, msg.sender);
    }

    /// @notice Liquida una propuesta no disputada tras el liveness (permisionless).
    function settle(uint256 id) external {
        Assertion storage a = assertions[id];
        if (a.state != State.Proposed) revert BadState();
        if (block.timestamp < a.proposedAt + LIVENESS) revert LivenessNotOver();
        a.state = State.Settled;
        payouts[a.proposer] += BOND;
        _publish(a.value, a.proposedAt);
        emit Settled(id, a.value, false, true);
    }

    /// @notice El árbitro resuelve una disputa.
    /// @param proposerCorrect true si el valor propuesto era correcto
    /// @param correctValue valor correcto (se publica si el proponente perdió)
    function resolve(uint256 id, bool proposerCorrect, uint256 correctValue) external {
        if (msg.sender != arbitrator) revert NotArbitrator();
        Assertion storage a = assertions[id];
        if (a.state != State.Disputed) revert BadState();
        a.state = State.Settled;
        uint256 fee = (BOND * ARBITRATION_FEE_BPS) / 10_000;
        feesCollected += fee;
        address winner = proposerCorrect ? a.proposer : a.disputer;
        payouts[winner] += 2 * BOND - fee;
        uint256 v = proposerCorrect ? a.value : correctValue;
        _publish(v, a.proposedAt);
        emit Settled(id, v, true, proposerCorrect);
    }

    function _publish(uint256 v, uint256 t) internal {
        if (t >= lastUpdated) {
            lastValue = v;
            lastUpdated = t;
        }
    }

    /// @notice Retiro de bonds y premios (pull).
    function claim() external nonReentrant {
        uint256 amt = payouts[msg.sender];
        payouts[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "envio fallido");
    }

    function withdrawFees() external nonReentrant {
        if (msg.sender != arbitrator) revert NotArbitrator();
        uint256 f = feesCollected;
        feesCollected = 0;
        (bool ok,) = msg.sender.call{value: f}("");
        require(ok, "envio fallido");
    }

    /// @inheritdoc IOracle
    function latest() external view returns (uint256, uint256) {
        if (lastUpdated == 0) revert NoData();
        return (lastValue, lastUpdated);
    }
}
