// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LeaseNFT} from "./LeaseNFT.sol";

/// @title RentVault — Escrow de contratos de alquiler sobre LeaseNFT
/// @notice Ciclo de vida:
///   1. `offer`: el dueño publica condiciones (inquilino, renta por período, períodos, depósito).
///   2. `accept`: el inquilino paga **depósito + primer período** y pasa a ser `userOf` hasta que
///      vence lo pagado + gracia.
///   3. `payRent(n)`: prepaga n períodos y **extiende el uso**. Si no paga, el uso expira solo
///      (el NFT corta el acceso sin que nadie intervenga).
///   4. `claimRent`: la renta de un período se libera al **dueño actual** del NFT cuando ese
///      período empieza (renta anticipada). El flujo de renta sigue al NFT: vender el NFT vende
///      también el contrato.
///   5. Morosidad: pasado período + gracia sin pago, el dueño puede `evict`. El depósito cubre un
///      período de renta como penalidad y el resto vuelve al inquilino.
///   6. Fin: `end` → ventana de 3 días para reclamar daños (con hash de evidencia), el inquilino
///      puede disputar → árbitro.
contract RentVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Offered,
        Active,
        Ended, // en ventana de daños
        Disputed,
        Closed
    }

    struct Lease {
        address tenant;
        uint128 rent; // por período
        uint128 deposit;
        uint64 period; // segundos
        uint32 totalPeriods;
        uint32 paidPeriods;
        uint32 claimedPeriods;
        uint64 start;
        uint64 endedAt;
        uint128 damageClaim;
        bytes32 evidence;
        Status status;
    }

    uint64 public constant GRACE = 3 days;
    uint64 public constant DAMAGE_WINDOW = 3 days;

    IERC20 public immutable token;
    LeaseNFT public immutable nft;
    address public immutable arbiter;
    mapping(uint256 => Lease) public leases; // por tokenId (un contrato activo por activo)

    event Offered(uint256 indexed id, address indexed tenant, uint256 rent, uint256 periods, uint256 deposit);
    event Accepted(uint256 indexed id, address indexed tenant, uint64 start);
    event RentPaid(uint256 indexed id, uint32 periods, uint64 usableUntil);
    event RentClaimed(uint256 indexed id, address indexed to, uint256 amount);
    event Evicted(uint256 indexed id, uint256 penalty, uint256 refund);
    event LeaseEnded(uint256 indexed id);
    event DamageClaimed(uint256 indexed id, uint256 amount, bytes32 evidence);
    event Disputed(uint256 indexed id);
    event Closed(uint256 indexed id, uint256 toLandlord, uint256 toTenant);

    error NotOwner();
    error NotTenant();
    error NotArbiter();
    error BadStatus();
    error BadTerms();
    error TooManyPeriods();
    error NotDelinquent();
    error NotOver();
    error WindowOpen();
    error WindowClosed();

    constructor(IERC20 _token, address _arbiter) {
        token = _token;
        arbiter = _arbiter;
        nft = new LeaseNFT(address(this));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @notice Índice del período actual (0-based).
    function currentPeriod(uint256 id) public view returns (uint256) {
        Lease storage l = leases[id];
        return (block.timestamp - l.start) / l.period;
    }

    /// @notice Hasta cuándo puede usar el inquilino (lo pagado + gracia).
    function usableUntil(Lease storage l) internal view returns (uint64) {
        return l.start + uint64(l.paidPeriods) * l.period + GRACE;
    }

    /// @notice Renta liberable al dueño: períodos pagados que YA empezaron.
    function claimable(uint256 id) public view returns (uint256) {
        Lease storage l = leases[id];
        if (l.start == 0 || block.timestamp < l.start) return 0;
        uint256 started = currentPeriod(id) + 1;
        if (started > l.totalPeriods) started = l.totalPeriods;
        uint256 upTo = started < l.paidPeriods ? started : l.paidPeriods;
        return upTo > l.claimedPeriods ? (upTo - l.claimedPeriods) * l.rent : 0;
    }

    // ------------------------------------------------------------------
    // Ciclo de vida
    // ------------------------------------------------------------------

    function offer(uint256 id, address tenant, uint128 rent, uint64 period, uint32 periods, uint128 deposit) external {
        if (nft.ownerOf(id) != msg.sender) revert NotOwner();
        Status s = leases[id].status;
        if (s != Status.None && s != Status.Closed && s != Status.Offered) revert BadStatus();
        if (tenant == address(0) || rent == 0 || period == 0 || periods == 0) revert BadTerms();
        leases[id] = Lease(tenant, rent, deposit, period, periods, 0, 0, 0, 0, 0, 0, Status.Offered);
        emit Offered(id, tenant, rent, periods, deposit);
    }

    function accept(uint256 id) external nonReentrant {
        Lease storage l = leases[id];
        if (l.status != Status.Offered) revert BadStatus();
        if (msg.sender != l.tenant) revert NotTenant();
        l.status = Status.Active;
        l.start = uint64(block.timestamp);
        l.paidPeriods = 1;
        token.safeTransferFrom(msg.sender, address(this), uint256(l.deposit) + l.rent);
        nft.setUser(id, l.tenant, usableUntil(l));
        emit Accepted(id, l.tenant, l.start);
    }

    /// @notice Prepaga `n` períodos (cualquiera puede pagar por el inquilino).
    function payRent(uint256 id, uint32 n) external nonReentrant {
        Lease storage l = leases[id];
        if (l.status != Status.Active) revert BadStatus();
        if (l.paidPeriods + n > l.totalPeriods) revert TooManyPeriods();
        l.paidPeriods += n;
        token.safeTransferFrom(msg.sender, address(this), uint256(l.rent) * n);
        uint64 until = usableUntil(l);
        nft.setUser(id, l.tenant, until);
        emit RentPaid(id, n, until);
    }

    /// @notice Libera la renta devengada al dueño ACTUAL del NFT.
    function claimRent(uint256 id) public nonReentrant returns (uint256 amt) {
        amt = claimable(id);
        if (amt == 0) return 0;
        Lease storage l = leases[id];
        l.claimedPeriods += uint32(amt / l.rent);
        address to = nft.ownerOf(id);
        token.safeTransfer(to, amt);
        emit RentClaimed(id, to, amt);
    }

    /// @notice Desalojo por morosidad: el período actual no está pagado y pasó la gracia.
    function evict(uint256 id) external {
        Lease storage l = leases[id];
        if (l.status != Status.Active) revert BadStatus();
        if (nft.ownerOf(id) != msg.sender) revert NotOwner();
        if (block.timestamp < usableUntil(l)) revert NotDelinquent();
        claimRent(id); // por si queda algo pagado sin liberar
        uint256 penalty = l.deposit < l.rent ? l.deposit : l.rent;
        uint256 refund = l.deposit - penalty;
        l.status = Status.Closed;
        nft.setUser(id, address(0), 0);
        if (penalty > 0) token.safeTransfer(msg.sender, penalty);
        if (refund > 0) token.safeTransfer(l.tenant, refund);
        emit Evicted(id, penalty, refund);
    }

    /// @notice Cierra el contrato tras el último período (cualquiera puede llamarlo).
    function end(uint256 id) external {
        Lease storage l = leases[id];
        if (l.status != Status.Active) revert BadStatus();
        if (block.timestamp < l.start + uint64(l.totalPeriods) * l.period) revert NotOver();
        if (l.paidPeriods < l.totalPeriods) revert BadStatus(); // moroso: usar evict
        claimRent(id);
        l.status = Status.Ended;
        l.endedAt = uint64(block.timestamp);
        nft.setUser(id, address(0), 0);
        emit LeaseEnded(id);
    }

    /// @notice El dueño reclama daños (≤ depósito) dentro de la ventana, con hash de evidencia (fotos o peritaje).
    function claimDamage(uint256 id, uint128 amount, bytes32 evidence) external {
        Lease storage l = leases[id];
        if (l.status != Status.Ended) revert BadStatus();
        if (nft.ownerOf(id) != msg.sender) revert NotOwner();
        if (block.timestamp > l.endedAt + DAMAGE_WINDOW) revert WindowClosed();
        if (amount > l.deposit) revert BadTerms();
        l.damageClaim = amount;
        l.evidence = evidence;
        emit DamageClaimed(id, amount, evidence);
    }

    /// @notice El inquilino disputa el reclamo: decide el árbitro.
    function dispute(uint256 id) external {
        Lease storage l = leases[id];
        if (l.status != Status.Ended || l.damageClaim == 0) revert BadStatus();
        if (msg.sender != l.tenant) revert NotTenant();
        if (block.timestamp > l.endedAt + 2 * DAMAGE_WINDOW) revert WindowClosed();
        l.status = Status.Disputed;
        emit Disputed(id);
    }

    /// @notice Sin disputa, tras dos ventanas: se aplica el reclamo y se devuelve el resto.
    function settle(uint256 id) external nonReentrant {
        Lease storage l = leases[id];
        if (l.status != Status.Ended) revert BadStatus();
        if (block.timestamp <= l.endedAt + 2 * DAMAGE_WINDOW) revert WindowOpen();
        _close(id, l.damageClaim);
    }

    /// @notice El árbitro fija el monto de daños final (≤ depósito).
    function resolve(uint256 id, uint128 toLandlord) external nonReentrant {
        if (msg.sender != arbiter) revert NotArbiter();
        Lease storage l = leases[id];
        if (l.status != Status.Disputed) revert BadStatus();
        if (toLandlord > l.deposit) revert BadTerms();
        _close(id, toLandlord);
    }

    function _close(uint256 id, uint256 toLandlord) internal {
        Lease storage l = leases[id];
        l.status = Status.Closed;
        uint256 toTenant = l.deposit - toLandlord;
        if (toLandlord > 0) token.safeTransfer(nft.ownerOf(id), toLandlord);
        if (toTenant > 0) token.safeTransfer(l.tenant, toTenant);
        emit Closed(id, toLandlord, toTenant);
    }
}
