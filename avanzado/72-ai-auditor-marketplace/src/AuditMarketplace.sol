// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AuditCertificate} from "./AuditCertificate.sol";

/// @title AuditMarketplace — Mercado de auditorías hechas por agentes IA
/// @notice
///  1. **Agentes**: un operador registra su agente (hash del modelo y del prompt, endpoint) con
///     **stake** en ETH, que es la garantía de calidad.
///  2. **Trabajos**: un cliente publica `target` + recompensa (escrow) + plazos.
///  3. **Commit-reveal**: los agentes envían `commit = keccak(jobId, agentId, reportHash, salt)`
///     y luego revelan. Así nadie copia informes ajenos.
///  4. **Selección**: el cliente elige ganador → pago (menos fee) → **certificado soulbound** al
///     cliente → reputación al agente.
///  5. **Anti-free-riding**: si hubo reveals, el cliente YA NO puede recuperar el escrow. Si no
///     elige antes de `reviewEnd`, la recompensa se reparte entre todos los que revelaron.
///  6. **Slashing**: el árbitro (DAO o comité) puede revocar un certificado si se demuestra un
///     exploit en el código certificado: se quema el 50% del stake del agente a favor del cliente.
/// @dev La "IA" corre off-chain: el contrato no ejecuta modelos. Registra compromisos, pagos,
///      reputación y garantías económicas, todo verificable.
contract AuditMarketplace is Ownable, ReentrancyGuard {
    // ------------------------------------------------------------------
    // Tipos y parámetros
    // ------------------------------------------------------------------

    struct Agent {
        address operator;
        bytes32 modelHash; // hash de los pesos o del modelo y la versión del prompt
        string endpoint; // API o descripción
        uint256 stake;
        uint64 unbondAt; // 0 = activo
        uint32 completed;
        uint32 slashed;
    }

    struct Job {
        address client;
        address target;
        bytes32 codehash; // código fijado al publicar
        uint256 reward;
        uint64 commitEnd;
        uint64 revealEnd;
        uint64 reviewEnd;
        bool settled;
        uint256[] revealed; // agentIds que revelaron
    }

    uint256 public constant MIN_STAKE = 1 ether;
    uint256 public constant UNBOND = 14 days;
    uint256 public constant FEE_BPS = 500; // 5% al protocolo
    uint256 public constant SLASH_BPS = 5_000; // 50%

    AuditCertificate public immutable certificate;
    uint256 public fees;

    Agent[] public agents; // id = índice + 1 (agents[0] se rellena con un placeholder)
    Job[] internal jobs;
    mapping(uint256 => mapping(uint256 => bytes32)) public commits; // job => agent => commit
    mapping(uint256 => mapping(uint256 => bytes32)) public reports; // job => agent => reportHash
    mapping(uint256 => uint256) public certAgent; // certId => agentId
    mapping(address => uint256) public credit; // pagos pull

    event AgentRegistered(uint256 indexed id, address indexed operator, bytes32 modelHash);
    event JobPosted(uint256 indexed id, address indexed client, address target, uint256 reward);
    event Committed(uint256 indexed jobId, uint256 indexed agentId);
    event Revealed(uint256 indexed jobId, uint256 indexed agentId, bytes32 reportHash);
    event Awarded(uint256 indexed jobId, uint256 indexed agentId, uint256 certId);
    event Split(uint256 indexed jobId, uint256 each);
    event Refunded(uint256 indexed jobId);
    event Slashed(uint256 indexed agentId, uint256 certId, uint256 amount);

    error LowStake();
    error NotOperator();
    error WrongPhase();
    error AlreadyCommitted();
    error BadReveal();
    error NotClient();
    error NotRevealed();
    error Settled();
    error HasReveals();
    error Unbonding();
    error NotUnbonding();
    error NoTarget();
    error NothingToClaim();

    constructor(address arbiter) Ownable(arbiter) {
        certificate = new AuditCertificate();
        agents.push(); // placeholder: los ids empiezan en 1
    }

    // ------------------------------------------------------------------
    // Agentes
    // ------------------------------------------------------------------

    function registerAgent(bytes32 modelHash, string calldata endpoint) external payable returns (uint256 id) {
        if (msg.value < MIN_STAKE) revert LowStake();
        id = agents.length;
        agents.push(Agent(msg.sender, modelHash, endpoint, msg.value, 0, 0, 0));
        emit AgentRegistered(id, msg.sender, modelHash);
    }

    /// @notice Inicia el unbonding: el agente deja de poder auditar y el stake queda 14 días expuesto a slashing.
    function startUnbond(uint256 id) external {
        Agent storage a = agents[id];
        if (a.operator != msg.sender) revert NotOperator();
        a.unbondAt = uint64(block.timestamp + UNBOND);
    }

    function withdrawStake(uint256 id) external nonReentrant {
        Agent storage a = agents[id];
        if (a.operator != msg.sender) revert NotOperator();
        if (a.unbondAt == 0 || block.timestamp < a.unbondAt) revert NotUnbonding();
        uint256 s = a.stake;
        a.stake = 0;
        credit[msg.sender] += s;
    }

    // ------------------------------------------------------------------
    // Trabajos
    // ------------------------------------------------------------------

    function postJob(address target, uint64 commitWindow, uint64 revealWindow, uint64 reviewWindow)
        external
        payable
        returns (uint256 id)
    {
        if (target.code.length == 0) revert NoTarget();
        id = jobs.length;
        Job storage j = jobs.push();
        j.client = msg.sender;
        j.target = target;
        j.codehash = target.codehash;
        j.reward = msg.value;
        j.commitEnd = uint64(block.timestamp) + commitWindow;
        j.revealEnd = j.commitEnd + revealWindow;
        j.reviewEnd = j.revealEnd + reviewWindow;
        emit JobPosted(id, msg.sender, target, msg.value);
    }

    /// @notice Hash a commitear (helper para agentes y tests).
    function commitHash(uint256 jobId, uint256 agentId, bytes32 reportHash, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(jobId, agentId, reportHash, salt));
    }

    function commit(uint256 jobId, uint256 agentId, bytes32 c) external {
        Agent storage a = agents[agentId];
        if (a.operator != msg.sender) revert NotOperator();
        if (a.unbondAt != 0) revert Unbonding();
        if (a.stake < MIN_STAKE) revert LowStake();
        if (block.timestamp > jobs[jobId].commitEnd) revert WrongPhase();
        if (commits[jobId][agentId] != 0) revert AlreadyCommitted();
        commits[jobId][agentId] = c;
        emit Committed(jobId, agentId);
    }

    function reveal(uint256 jobId, uint256 agentId, bytes32 reportHash, bytes32 salt) external {
        Job storage j = jobs[jobId];
        if (agents[agentId].operator != msg.sender) revert NotOperator();
        if (block.timestamp <= j.commitEnd || block.timestamp > j.revealEnd) revert WrongPhase();
        bytes32 c = commits[jobId][agentId];
        if (c == 0 || c != commitHash(jobId, agentId, reportHash, salt) || reports[jobId][agentId] != 0) {
            revert BadReveal();
        }
        reports[jobId][agentId] = reportHash;
        j.revealed.push(agentId);
        emit Revealed(jobId, agentId, reportHash);
    }

    /// @notice El cliente elige el informe ganador (en la fase de revisión).
    function award(uint256 jobId, uint256 agentId) external nonReentrant returns (uint256 certId) {
        Job storage j = jobs[jobId];
        if (msg.sender != j.client) revert NotClient();
        if (block.timestamp <= j.revealEnd || block.timestamp > j.reviewEnd) revert WrongPhase();
        if (j.settled) revert Settled();
        bytes32 rh = reports[jobId][agentId];
        if (rh == 0) revert NotRevealed();
        j.settled = true;

        uint256 fee = (j.reward * FEE_BPS) / 10_000;
        fees += fee;
        Agent storage a = agents[agentId];
        credit[a.operator] += j.reward - fee;
        a.completed++;

        certId = certificate.issue(
            j.client,
            AuditCertificate.Cert(j.target, j.codehash, agentId, rh, uint64(block.timestamp), false)
        );
        certAgent[certId] = agentId;
        emit Awarded(jobId, agentId, certId);
    }

    /// @notice Pasado `reviewEnd` sin decisión: reparte entre los que revelaron, o reembolsa si nadie reveló.
    function settleExpired(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (block.timestamp <= j.reviewEnd) revert WrongPhase();
        if (j.settled) revert Settled();
        j.settled = true;
        uint256 n = j.revealed.length;
        if (n == 0) {
            credit[j.client] += j.reward;
            emit Refunded(jobId);
            return;
        }
        uint256 fee = (j.reward * FEE_BPS) / 10_000;
        uint256 each = (j.reward - fee) / n;
        fees += j.reward - each * n; // fee + polvo de redondeo
        for (uint256 i = 0; i < n; i++) {
            credit[agents[j.revealed[i]].operator] += each;
        }
        emit Split(jobId, each);
    }

    /// @notice Reembolso anticipado solo si NO hubo reveals (ningún informe expuesto).
    function cancel(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (msg.sender != j.client) revert NotClient();
        if (block.timestamp <= j.revealEnd) revert WrongPhase();
        if (j.settled) revert Settled();
        if (j.revealed.length != 0) revert HasReveals();
        j.settled = true;
        credit[j.client] += j.reward;
        emit Refunded(jobId);
    }

    // ------------------------------------------------------------------
    // Árbitro: revocar + slashing
    // ------------------------------------------------------------------

    /// @notice Se demostró un bug crítico en código certificado: revoca y slashea al agente.
    function revokeAndSlash(uint256 certId, string calldata reason) external onlyOwner {
        uint256 agentId = certAgent[certId];
        Agent storage a = agents[agentId];
        uint256 amount = (a.stake * SLASH_BPS) / 10_000;
        a.stake -= amount;
        a.slashed++;
        credit[certificate.ownerOf(certId)] += amount; // compensa al cliente
        certificate.revoke(certId, reason);
        emit Slashed(agentId, certId, amount);
    }

    // ------------------------------------------------------------------
    // Pagos pull
    // ------------------------------------------------------------------

    function claim() external nonReentrant {
        uint256 amt = credit[msg.sender];
        if (amt == 0) revert NothingToClaim();
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "envio fallido");
    }

    function withdrawFees(address to) external onlyOwner {
        uint256 f = fees;
        fees = 0;
        credit[to] += f;
    }

    // ------------------------------------------------------------------
    // Vistas
    // ------------------------------------------------------------------

    /// @notice Reputación simple: completados − 3 × slasheados (piso 0).
    function reputation(uint256 agentId) external view returns (uint256) {
        Agent storage a = agents[agentId];
        uint256 penalty = uint256(a.slashed) * 3;
        return a.completed > penalty ? a.completed - penalty : 0;
    }

    function revealedCount(uint256 jobId) external view returns (uint256) {
        return jobs[jobId].revealed.length;
    }
}
