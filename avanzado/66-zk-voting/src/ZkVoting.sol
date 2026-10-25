// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Interfaz mínima de un verificador Groth16 (la que genera snarkjs).
interface IGroth16Verifier {
    function verifyProof(uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c, uint256[] calldata input)
        external
        view
        returns (bool);
}

/// @title ZkVoting — Votación anónima con pruebas de conocimiento cero (estilo Semaphore)
/// @notice Cada votante registra off-chain un *identity commitment* = Poseidon(secreto, nullifierKey).
///         El registrador publica la raíz Merkle de los commitments elegibles. Para votar,
///         el votante genera una prueba Groth16 que demuestra, SIN revelar cuál es su hoja:
///           1. conoce un secreto cuyo commitment está en el árbol con raíz `root`;
///           2. `nullifierHash = Poseidon(nullifierKey, proposalId)` (único por persona y propuesta);
///           3. el voto `option` queda atado a la prueba (input público).
///         On-chain verificamos la prueba, que la raíz sea la de la propuesta y que el
///         nullifier no se haya usado. Así hay **una persona, un voto** y anonimato.
/// @dev Inputs públicos (orden fijo, debe coincidir con el circuito):
///         [0] root, [1] nullifierHash, [2] proposalId, [3] option
contract ZkVoting is Ownable {
    struct Proposal {
        bytes32 descriptionHash; // hash del texto (IPFS)
        uint256 root; // snapshot de la raíz de elegibles al crear la propuesta
        uint64 start;
        uint64 end;
        uint8 numOptions;
        bool exists;
    }

    IGroth16Verifier public immutable verifier;
    /// @notice Raíz Merkle actual de votantes elegibles (Poseidon, calculada off-chain).
    uint256 public currentRoot;
    uint256 public proposalCount;

    mapping(uint256 => Proposal) public proposals;
    /// @notice proposalId => opción => votos
    mapping(uint256 => mapping(uint256 => uint256)) public tally;
    /// @notice nullifierHash => usado (impide votar dos veces)
    mapping(uint256 => bool) public nullifierUsed;

    event RootUpdated(uint256 root);
    event ProposalCreated(uint256 indexed id, uint256 root, uint64 start, uint64 end, uint8 numOptions);
    event VoteCast(uint256 indexed proposalId, uint256 option, uint256 nullifierHash);

    error UnknownProposal();
    error VotingClosed();
    error InvalidOption();
    error NullifierAlreadyUsed();
    error InvalidProof();
    error RootMismatch();
    error BadWindow();

    constructor(IGroth16Verifier _verifier, address registrar) Ownable(registrar) {
        verifier = _verifier;
    }

    /// @notice El registrador actualiza la raíz cuando se suman votantes.
    /// @dev Propuestas ya creadas mantienen su snapshot: agregar votantes no altera votaciones en curso.
    function setRoot(uint256 root) external onlyOwner {
        currentRoot = root;
        emit RootUpdated(root);
    }

    /// @notice Crea una propuesta tomando snapshot de la raíz actual.
    function createProposal(bytes32 descriptionHash, uint64 start, uint64 end, uint8 numOptions)
        external
        onlyOwner
        returns (uint256 id)
    {
        if (end <= start || end <= block.timestamp || numOptions < 2) revert BadWindow();
        id = ++proposalCount;
        proposals[id] = Proposal(descriptionHash, currentRoot, start, end, numOptions, true);
        emit ProposalCreated(id, currentRoot, start, end, numOptions);
    }

    /// @notice Emite un voto anónimo. Cualquiera puede enviarlo (un relayer, para ocultar
    ///         también la dirección que paga el gas).
    function vote(
        uint256 proposalId,
        uint256 option,
        uint256 nullifierHash,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert UnknownProposal();
        if (block.timestamp < p.start || block.timestamp > p.end) revert VotingClosed();
        if (option >= p.numOptions) revert InvalidOption();
        if (nullifierUsed[nullifierHash]) revert NullifierAlreadyUsed();

        // Los inputs públicos se arman ON-CHAIN con los valores esperados: el votante
        // no puede elegir otra raíz ni otra propuesta.
        uint256[] memory input = new uint256[](4);
        input[0] = p.root;
        input[1] = nullifierHash;
        input[2] = proposalId;
        input[3] = option;
        if (!verifier.verifyProof(a, b, c, input)) revert InvalidProof();

        // Efectos después de verificar (no hay llamadas externas que modifiquen estado)
        nullifierUsed[nullifierHash] = true;
        tally[proposalId][option] += 1;
        emit VoteCast(proposalId, option, nullifierHash);
    }

    /// @notice Resultado completo de una propuesta.
    function results(uint256 proposalId) external view returns (uint256[] memory r) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert UnknownProposal();
        r = new uint256[](p.numOptions);
        for (uint256 i = 0; i < p.numOptions; i++) r[i] = tally[proposalId][i];
    }
}
