// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PropertyRegistry} from "./PropertyRegistry.sol";

/// @title PropertyShares — Fracciones de un inmueble: votos + renta pro-rata
/// @notice ERC-20 con:
///   - **ERC20Votes**: checkpoints históricos, así un flash loan no da votos en propuestas ya creadas.
///     Auto-delegación a uno mismo para que los votos estén activos sin pasos extra.
///   - **Transferencias restringidas a KYC** (`registry.isVerified`).
///   - **Dividendos de renta** con acumulador "magnificado" (patrón ERC-1726/2222): los
///     inquilinos pagan con `depositRent`, cada holder retira lo suyo con `withdrawRent`.
///     Las transferencias ajustan correcciones para que nadie cobre renta que no le toca.
contract PropertyShares is ERC20, ERC20Votes, ReentrancyGuard {
    uint256 private constant MAG = 2 ** 128;

    PropertyRegistry public immutable registry;
    uint256 public immutable propertyId;

    uint256 public magnifiedPerShare;
    mapping(address => int256) internal corrections;
    mapping(address => uint256) public withdrawn;

    event RentDeposited(address indexed from, uint256 amount);
    event RentWithdrawn(address indexed to, uint256 amount);

    error NotVerified(address who);
    error NoSupply();
    error NothingToWithdraw();

    constructor(
        string memory name_,
        string memory symbol_,
        PropertyRegistry _registry,
        uint256 _propertyId,
        address[] memory holders,
        uint256[] memory amounts
    ) ERC20(name_, symbol_) EIP712(name_, "1") {
        registry = _registry;
        propertyId = _propertyId;
        for (uint256 i = 0; i < holders.length; i++) _mint(holders[i], amounts[i]);
    }

    // ------------------------------------------------------------------
    // Renta
    // ------------------------------------------------------------------

    /// @notice Cualquiera (inquilino, administrador o la DAO) deposita renta en ETH.
    function depositRent() public payable {
        uint256 s = totalSupply();
        if (s == 0) revert NoSupply();
        magnifiedPerShare += (msg.value * MAG) / s;
        emit RentDeposited(msg.sender, msg.value);
    }

    receive() external payable {
        depositRent();
    }

    /// @notice Renta acumulada total de `a` (cobrada + pendiente).
    function accumulativeRentOf(address a) public view returns (uint256) {
        return uint256(int256(magnifiedPerShare * balanceOf(a)) + corrections[a]) / MAG;
    }

    function withdrawableRentOf(address a) public view returns (uint256) {
        return accumulativeRentOf(a) - withdrawn[a];
    }

    function withdrawRent() external nonReentrant {
        uint256 amt = withdrawableRentOf(msg.sender);
        if (amt == 0) revert NothingToWithdraw();
        withdrawn[msg.sender] += amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "envio fallido");
        emit RentWithdrawn(msg.sender, amt);
    }

    // ------------------------------------------------------------------
    // Hook de transferencias
    // ------------------------------------------------------------------

    /// @dev Orden: (1) KYC, (2) correcciones de dividendos, (3) checkpoints de votos, (4) auto-delegación.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (to != address(0) && !registry.isVerified(to)) revert NotVerified(to);
        if (from != address(0) && !registry.isVerified(from)) revert NotVerified(from);

        int256 corr = int256(magnifiedPerShare * value);
        if (from != address(0)) corrections[from] += corr; // el emisor "se lleva" lo devengado
        if (to != address(0)) corrections[to] -= corr; // el receptor no cobra lo pasado

        super._update(from, to, value);

        if (to != address(0) && delegates(to) == address(0)) _delegate(to, to);
    }
}
