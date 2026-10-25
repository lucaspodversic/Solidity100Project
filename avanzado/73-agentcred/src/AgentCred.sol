// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title AgentCred — Identidad y reputación de agentes de IA sobre ERC-721
/// @notice Cada agente es un NFT. Su confiabilidad se apoya en dos pilares:
///
///  **1. Atestación TEE (cómputo confidencial):** el agente corre dentro de un enclave
///     (Intel TDX/SGX, AMD SEV, AWS Nitro). El enclave genera una clave `agentKey` que nunca sale
///     de él y produce un *quote* que incluye la **medición** del código (MRENCLAVE / RTMR) y la
///     clave pública. Verificar el quote on-chain (DCAP completo) es caro, así que acá un
///     **verificador de atestaciones** autorizado lo hace off-chain y firma (EIP-712):
///         `Attestation(agentId, agentKey, measurement, expiry)`
///     Además, la propia `agentKey` firma `Binding(agentId, owner)`: prueba de posesión, para que
///     nadie reutilice la atestación de otro agente.
///
///  **2. Reputación anti-sybil:** solo se puede calificar con un **recibo** firmado por la
///     `agentKey` (el agente reconoce haber hecho la tarea `taskId` para `client`). Cada recibo se
///     usa una vez y solo lo usa ese cliente.
///
/// @dev La reputación está atada a la **medición**: si el agente cambia de código, se resetea.
///      Transferir el NFT invalida la atestación (el nuevo dueño debe re-atestar).
contract AgentCred is ERC721, Ownable, EIP712 {
    struct Agent {
        address agentKey;
        bytes32 measurement;
        uint64 attestedUntil;
        string metadataURI;
        // reputación
        uint64 ratings;
        uint64 scoreSum; // suma de 1..5
        bytes32 repMeasurement;
    }

    bytes32 public constant ATTESTATION_TYPEHASH =
        keccak256("Attestation(uint256 agentId,address agentKey,bytes32 measurement,uint64 expiry)");
    bytes32 public constant BINDING_TYPEHASH = keccak256("Binding(uint256 agentId,address owner)");
    bytes32 public constant RECEIPT_TYPEHASH = keccak256("Receipt(uint256 agentId,bytes32 taskId,address client)");

    uint256 public nextId = 1;
    mapping(uint256 => Agent) public agents;
    mapping(address => bool) public isVerifier; // verificadores de quotes TEE
    mapping(bytes32 => bool) public approvedMeasurement; // builds auditados/reproducibles
    mapping(uint256 => mapping(bytes32 => bool)) public receiptUsed;

    event AgentRegistered(uint256 indexed id, address indexed owner, string uri);
    event Attested(uint256 indexed id, address agentKey, bytes32 measurement, uint64 expiry);
    event Rated(uint256 indexed id, address indexed client, bytes32 taskId, uint8 score);
    event ReputationReset(uint256 indexed id, bytes32 newMeasurement);
    event VerifierSet(address v, bool ok);
    event MeasurementSet(bytes32 m, bool ok);

    error NotAgentOwner();
    error BadVerifier();
    error BadBinding();
    error MeasurementNotApproved();
    error Expired();
    error NotTrusted();
    error BadReceipt();
    error ReceiptUsed();
    error BadScore();

    constructor(address governance) ERC721("AgentCred", "AGENT") Ownable(governance) EIP712("AgentCred", "1") {}

    // ------------------------------------------------------------------
    // Gobernanza
    // ------------------------------------------------------------------

    function setVerifier(address v, bool ok) external onlyOwner {
        isVerifier[v] = ok;
        emit VerifierSet(v, ok);
    }

    /// @notice Aprueba o revoca un build. Revocarlo deja a todos sus agentes como no confiables
    ///         al instante (p. ej. si se descubre una vulnerabilidad en esa versión).
    function setMeasurement(bytes32 m, bool ok) external onlyOwner {
        approvedMeasurement[m] = ok;
        emit MeasurementSet(m, ok);
    }

    // ------------------------------------------------------------------
    // Identidad
    // ------------------------------------------------------------------

    function register(string calldata uri) external returns (uint256 id) {
        id = nextId++;
        agents[id].metadataURI = uri;
        _mint(msg.sender, id);
        emit AgentRegistered(id, msg.sender, uri);
    }

    /// @notice Registra o renueva la atestación TEE.
    /// @param verifierSig firma EIP-712 del verificador sobre Attestation(...)
    /// @param keySig firma EIP-712 de `agentKey` sobre Binding(agentId, owner)
    function attest(
        uint256 id,
        address agentKey,
        bytes32 measurement,
        uint64 expiry,
        bytes calldata verifierSig,
        bytes calldata keySig
    ) external {
        if (ownerOf(id) != msg.sender) revert NotAgentOwner();
        if (expiry <= block.timestamp) revert Expired();
        if (!approvedMeasurement[measurement]) revert MeasurementNotApproved();

        bytes32 a = _hashTypedDataV4(keccak256(abi.encode(ATTESTATION_TYPEHASH, id, agentKey, measurement, expiry)));
        if (!isVerifier[ECDSA.recover(a, verifierSig)]) revert BadVerifier();

        bytes32 b = _hashTypedDataV4(keccak256(abi.encode(BINDING_TYPEHASH, id, msg.sender)));
        if (ECDSA.recover(b, keySig) != agentKey) revert BadBinding();

        Agent storage ag = agents[id];
        ag.agentKey = agentKey;
        ag.measurement = measurement;
        ag.attestedUntil = expiry;

        // código nuevo ⇒ la reputación anterior no aplica
        if (ag.repMeasurement != measurement) {
            ag.repMeasurement = measurement;
            ag.ratings = 0;
            ag.scoreSum = 0;
            emit ReputationReset(id, measurement);
        }
        emit Attested(id, agentKey, measurement, expiry);
    }

    /// @notice ¿Se puede confiar hoy en este agente?
    function isTrusted(uint256 id) public view returns (bool) {
        Agent storage ag = agents[id];
        return ag.agentKey != address(0) && block.timestamp < ag.attestedUntil && approvedMeasurement[ag.measurement];
    }

    /// @notice Verifica que un mensaje fue firmado por el agente desde su enclave (útil para otros contratos).
    function verifyAgentSignature(uint256 id, bytes32 digest, bytes calldata sig) external view returns (bool) {
        return isTrusted(id) && ECDSA.recover(digest, sig) == agents[id].agentKey;
    }

    // ------------------------------------------------------------------
    // Reputación
    // ------------------------------------------------------------------

    /// @notice El cliente califica (1..5) una tarea con el recibo firmado por el agente.
    function rate(uint256 id, bytes32 taskId, uint8 score, bytes calldata receiptSig) external {
        if (score < 1 || score > 5) revert BadScore();
        if (!isTrusted(id)) revert NotTrusted();
        if (receiptUsed[id][taskId]) revert ReceiptUsed();
        bytes32 d = _hashTypedDataV4(keccak256(abi.encode(RECEIPT_TYPEHASH, id, taskId, msg.sender)));
        if (ECDSA.recover(d, receiptSig) != agents[id].agentKey) revert BadReceipt();
        receiptUsed[id][taskId] = true;
        Agent storage ag = agents[id];
        ag.ratings++;
        ag.scoreSum += score;
        emit Rated(id, msg.sender, taskId, score);
    }

    /// @notice Promedio ×100 (p. ej. 450 = 4,50) y cantidad de calificaciones.
    function reputation(uint256 id) external view returns (uint256 avgX100, uint256 count) {
        Agent storage ag = agents[id];
        count = ag.ratings;
        avgX100 = count == 0 ? 0 : (uint256(ag.scoreSum) * 100) / count;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return agents[id].metadataURI;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev Transferir invalida la atestación: la clave del enclave estaba ligada al dueño anterior.
    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (from != address(0) && to != address(0)) {
            agents[id].agentKey = address(0);
            agents[id].attestedUntil = 0;
        }
    }
}
