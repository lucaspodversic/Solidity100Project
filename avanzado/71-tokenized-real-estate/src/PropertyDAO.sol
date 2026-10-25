// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PropertyShares} from "./PropertyShares.sol";
import {PropertyRegistry} from "./PropertyRegistry.sol";

/// @title PropertyDAO — Gobierno de un inmueble tokenizado
/// @notice La DAO **custodia el NFT** del inmueble. Los holders de `PropertyShares` proponen y
///         votan acciones arbitrarias (pagar mantenimiento, contratar administrador, cambiar
///         alquiler) y la **venta**: compradores dejan ofertas en escrow; si la DAO acepta, el
///         NFT pasa al comprador y el ETH se reparte como "renta" a los holders.
/// @dev Seguridad de gobernanza:
///   - Votos con snapshot `block.number - 1` al crear la propuesta (anti flash loan).
///   - Umbral para proponer (1% del supply), quórum (20%) y mayoría simple.
///   - **Timelock** de 2 días entre aprobación y ejecución (los disconformes pueden vender).
contract PropertyDAO is IERC721Receiver, ReentrancyGuard {
    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        string description;
        uint256 snapshot; // bloque
        uint64 voteEnd;
        uint64 eta; // ejecutable desde (0 = no encolada)
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
    }

    struct Offer {
        address buyer;
        uint256 amount;
        bool active;
    }

    uint256 public constant VOTING_PERIOD = 5 days;
    uint256 public constant TIMELOCK = 2 days;
    uint256 public constant PROPOSAL_THRESHOLD_BPS = 100; // 1%
    uint256 public constant QUORUM_BPS = 2_000; // 20%

    PropertyShares public shares;
    PropertyRegistry public immutable registry;
    uint256 public immutable propertyId;
    address private immutable deployer;

    Proposal[] internal proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    Offer[] public offers;
    /// @notice ETH de ofertas en escrow: NO se puede gastar con `pay`.
    uint256 public escrowed;

    event Proposed(uint256 indexed id, address indexed proposer, address target, string description);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event Queued(uint256 indexed id, uint256 eta);
    event Executed(uint256 indexed id);
    event OfferMade(uint256 indexed id, address indexed buyer, uint256 amount);
    event OfferWithdrawn(uint256 indexed id);
    event Sold(address indexed buyer, uint256 amount);

    error BelowThreshold();
    error VotingClosed();
    error AlreadyVoted();
    error NoVotes();
    error NotPassed();
    error TooEarly();
    error AlreadyExecuted();
    error OnlySelf();
    error OfferInactive();
    error NotBuyer();
    error CallFailed();
    error AlreadyInit();
    error EscrowLocked();

    constructor(PropertyRegistry _registry, uint256 _propertyId) {
        registry = _registry;
        propertyId = _propertyId;
        deployer = msg.sender;
    }

    /// @notice Conecta el token de fracciones (se despliega después para conocer la dirección de la DAO).
    function init(PropertyShares s) external {
        if (msg.sender != deployer || address(shares) != address(0)) revert AlreadyInit();
        shares = s;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    // ------------------------------------------------------------------
    // Gobernanza
    // ------------------------------------------------------------------

    function propose(address target, uint256 value, bytes calldata data, string calldata description)
        external
        returns (uint256 id)
    {
        uint256 snap = block.number - 1;
        if (shares.getPastVotes(msg.sender, snap) * 10_000 < shares.getPastTotalSupply(snap) * PROPOSAL_THRESHOLD_BPS) {
            revert BelowThreshold();
        }
        id = proposals.length;
        proposals.push(
            Proposal(msg.sender, target, value, data, description, snap, uint64(block.timestamp + VOTING_PERIOD), 0, 0, 0, false)
        );
        emit Proposed(id, msg.sender, target, description);
    }

    function vote(uint256 id, bool support) external {
        Proposal storage p = proposals[id];
        if (block.timestamp > p.voteEnd) revert VotingClosed();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        uint256 w = shares.getPastVotes(msg.sender, p.snapshot);
        if (w == 0) revert NoVotes();
        hasVoted[id][msg.sender] = true;
        if (support) p.forVotes += w;
        else p.againstVotes += w;
        emit Voted(id, msg.sender, support, w);
    }

    /// @notice ¿Aprobada? (votación terminada, quórum y mayoría)
    function passed(uint256 id) public view returns (bool) {
        Proposal storage p = proposals[id];
        if (block.timestamp <= p.voteEnd) return false;
        uint256 supply = shares.getPastTotalSupply(p.snapshot);
        return (p.forVotes + p.againstVotes) * 10_000 >= supply * QUORUM_BPS && p.forVotes > p.againstVotes;
    }

    function queue(uint256 id) external {
        if (!passed(id)) revert NotPassed();
        Proposal storage p = proposals[id];
        if (p.eta != 0) revert AlreadyExecuted();
        p.eta = uint64(block.timestamp + TIMELOCK);
        emit Queued(id, p.eta);
    }

    function execute(uint256 id) external nonReentrant {
        Proposal storage p = proposals[id];
        if (p.eta == 0 || block.timestamp < p.eta) revert TooEarly();
        if (p.executed) revert AlreadyExecuted();
        p.executed = true;
        (bool ok,) = p.target.call{value: p.value}(p.data);
        if (!ok) revert CallFailed();
        emit Executed(id);
    }

    function getProposal(uint256 id) external view returns (uint256 forVotes, uint256 againstVotes, bool executed) {
        Proposal storage p = proposals[id];
        return (p.forVotes, p.againstVotes, p.executed);
    }

    // ------------------------------------------------------------------
    // Venta del inmueble
    // ------------------------------------------------------------------

    /// @notice Un comprador (con KYC) deja ETH en escrow como oferta.
    function makeOffer() external payable returns (uint256 id) {
        id = offers.length;
        offers.push(Offer(msg.sender, msg.value, true));
        escrowed += msg.value;
        emit OfferMade(id, msg.sender, msg.value);
    }

    /// @notice El comprador puede retirar su oferta mientras no se acepte.
    function withdrawOffer(uint256 id) external nonReentrant {
        Offer storage o = offers[id];
        if (!o.active) revert OfferInactive();
        if (o.buyer != msg.sender) revert NotBuyer();
        o.active = false;
        escrowed -= o.amount;
        (bool ok,) = msg.sender.call{value: o.amount}("");
        if (!ok) revert CallFailed();
        emit OfferWithdrawn(id);
    }

    /// @notice Solo vía propuesta: vende el NFT y reparte el ETH a los holders.
    function acceptOffer(uint256 id) external onlySelf {
        Offer storage o = offers[id];
        if (!o.active) revert OfferInactive();
        o.active = false;
        escrowed -= o.amount;
        registry.safeTransferFrom(address(this), o.buyer, propertyId);
        shares.depositRent{value: o.amount}();
        emit Sold(o.buyer, o.amount);
    }

    /// @notice Solo vía propuesta: pagar un gasto (mantenimiento, impuestos).
    function pay(address payable to, uint256 amount) external onlySelf {
        if (amount > address(this).balance - escrowed) revert EscrowLocked();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert CallFailed();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Fondo operativo (p. ej. reserva para mantenimiento).
    receive() external payable {}
}
