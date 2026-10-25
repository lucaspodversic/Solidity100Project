// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TokenVesting — vesting lineal con cliff para ERC20
/// @author Proyecto 39
/// @notice El dueño crea grants: beneficiary, amount, start, cliff, duration.
///         El beneficiary reclama lo vestido con `release`. Revocable opcionalmente.
contract TokenVesting is Ownable, ReentrancyGuard {
    struct Grant {
        address beneficiary;
        uint256 total;
        uint256 released;
        uint64 start;
        uint64 cliff;
        uint64 duration;
        bool revocable;
        bool revoked;
    }
    IERC20 public immutable token;
    uint256 public nextId = 1;
    mapping(uint256 => Grant) public grants;

    event GrantCreated(uint256 id, address beneficiary, uint256 total);
    event Released(uint256 id, uint256 amount);
    event Revoked(uint256 id, uint256 refund);

    error BadParams(); error Nothing(); error NotBene(); error NotRevocable();

    constructor(address token_) Ownable(msg.sender) { token = IERC20(token_); }

    function createGrant(
        address beneficiary, uint256 total, uint64 start, uint64 cliff, uint64 duration, bool revocable
    ) external onlyOwner returns (uint256 id) {
        if (beneficiary == address(0) || total == 0 || duration == 0 || cliff > duration) revert BadParams();
        if (!token.transferFrom(msg.sender, address(this), total)) revert BadParams();
        id = nextId++;
        grants[id] = Grant(beneficiary, total, 0, start, cliff, duration, revocable, false);
        emit GrantCreated(id, beneficiary, total);
    }

    /// @notice Cantidad ya vestida (no necesariamente liberada).
    function vestedAmount(uint256 id) public view returns (uint256) {
        Grant memory g = grants[id];
        if (g.revoked) return g.released;
        if (block.timestamp < g.start + g.cliff) return 0;
        if (block.timestamp >= g.start + g.duration) return g.total;
        return (g.total * (block.timestamp - g.start)) / g.duration;
    }

    function releasable(uint256 id) public view returns (uint256) {
        return vestedAmount(id) - grants[id].released;
    }

    function release(uint256 id) external nonReentrant {
        Grant storage g = grants[id];
        if (msg.sender != g.beneficiary) revert NotBene();
        uint256 amount = releasable(id);
        if (amount == 0) revert Nothing();
        g.released += amount;
        if (!token.transfer(g.beneficiary, amount)) revert Nothing();
        emit Released(id, amount);
    }

    function revoke(uint256 id) external onlyOwner nonReentrant {
        Grant storage g = grants[id];
        if (!g.revocable || g.revoked) revert NotRevocable();
        uint256 vested = vestedAmount(id);
        uint256 refund = g.total - vested;
        g.revoked = true;
        // liberamos lo vestido al beneficiary y devolvemos el resto al owner
        uint256 pending = vested - g.released;
        g.released = vested;
        if (pending > 0) token.transfer(g.beneficiary, pending);
        if (refund > 0) token.transfer(owner(), refund);
        emit Revoked(id, refund);
    }
}
