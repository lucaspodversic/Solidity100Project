// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title RebaseToken — Token cuyo balance crece con el tiempo (interés lineal por usuario)
/// @notice `balanceOf(u) = principal(u) × (1 + rate(u) × Δt)`.
///         - Cada usuario tiene una **tasa propia** fijada al depositar (la tasa global vigente).
///         - La tasa global **solo puede bajar**: premia a los primeros depositantes.
///         - Antes de cualquier mint/burn/transfer se "cristaliza" el interés acumulado
///           (se acuña como principal) y se reinicia el reloj.
/// @dev `totalSupply()` devuelve solo el principal cristalizado (no incluye interés pendiente):
///      calcularlo exacto requeriría iterar todos los usuarios. Está documentado.
contract RebaseToken is ERC20, AccessControl {
    bytes32 public constant MINT_BURN_ROLE = keccak256("MINT_BURN_ROLE");
    uint256 private constant PRECISION = 1e18;

    /// @notice Tasa global por segundo (1e18 = 100%/s). 1e9 ≈ 3,15% anual.
    uint256 public globalRate = 1e9;
    mapping(address => uint256) public userRate;
    mapping(address => uint256) public lastUpdated;

    event GlobalRateSet(uint256 rate);

    error RateCanOnlyDecrease(uint256 current, uint256 proposed);

    constructor() ERC20("Cross-Chain Rebase Token", "RBT") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Baja la tasa global (nunca la sube).
    function setGlobalRate(uint256 r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (r > globalRate) revert RateCanOnlyDecrease(globalRate, r);
        globalRate = r;
        emit GlobalRateSet(r);
    }

    // ------------------------------------------------------------------
    // Balances
    // ------------------------------------------------------------------

    /// @notice Principal sin el interés pendiente.
    function principalOf(address u) public view returns (uint256) {
        return super.balanceOf(u);
    }

    /// @notice Balance con interés lineal acumulado desde la última actualización.
    function balanceOf(address u) public view override returns (uint256) {
        uint256 p = super.balanceOf(u);
        if (p == 0) return 0;
        uint256 dt = block.timestamp - lastUpdated[u];
        return (p * (PRECISION + userRate[u] * dt)) / PRECISION;
    }

    /// @dev Acuña el interés pendiente como principal y reinicia el reloj.
    function _accrue(address u) internal {
        uint256 pending = balanceOf(u) - super.balanceOf(u);
        lastUpdated[u] = block.timestamp;
        if (pending > 0) _mint(u, pending);
    }

    // ------------------------------------------------------------------
    // Mint / burn (vault y token pool)
    // ------------------------------------------------------------------

    /// @notice Acuña fijando la tasa del usuario.
    /// @param rate tasa a asignar: el vault pasa `globalRate`; el bridge pasa la tasa de origen.
    /// @dev Si el usuario ya tiene balance, se queda con la MENOR de las dos tasas: así nadie
    ///      puede "subir" su tasa trayendo tokens de otra cadena.
    function mint(address to, uint256 amount, uint256 rate) external onlyRole(MINT_BURN_ROLE) {
        _accrue(to);
        if (super.balanceOf(to) == 0 || rate < userRate[to]) userRate[to] = rate;
        _mint(to, amount);
    }

    /// @notice Quema (tras cristalizar el interés). `type(uint256).max` = todo el balance.
    function burn(address from, uint256 amount) external onlyRole(MINT_BURN_ROLE) returns (uint256) {
        _accrue(from);
        if (amount == type(uint256).max) amount = super.balanceOf(from);
        _burn(from, amount);
        return amount;
    }

    // ------------------------------------------------------------------
    // Transferencias
    // ------------------------------------------------------------------

    function transfer(address to, uint256 amount) public override returns (bool) {
        _beforeMove(msg.sender, to);
        if (amount == type(uint256).max) amount = super.balanceOf(msg.sender);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _beforeMove(from, to);
        if (amount == type(uint256).max) amount = super.balanceOf(from);
        return super.transferFrom(from, to, amount);
    }

    /// @dev Cristaliza ambos lados; el receptor sin balance hereda la tasa del emisor.
    function _beforeMove(address from, address to) internal {
        _accrue(from);
        _accrue(to);
        if (super.balanceOf(to) == 0) userRate[to] = userRate[from];
    }
}
