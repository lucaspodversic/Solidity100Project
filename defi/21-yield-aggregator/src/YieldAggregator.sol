// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title YieldAggregator — registro, medición y ranking de fuentes de rendimiento ERC-4626
/// @notice Compara vaults del mismo asset por **APY medido on-chain**, **TVL** y **riesgo**
///         (asignado por gobernanza), y ofrece un router que deposita en la mejor opción.
///
///  - **APY medido, no declarado:** `poke()` toma una foto del precio por share (pps) de cada
///    vault. El APY sale de la variación del pps entre fotos separadas por al menos
///    `MIN_WINDOW`, anualizada y suavizada con una EMA (30 % nuevo / 70 % viejo).
///  - **Score:** `score = apy · (1 − riesgo)`. Son elegibles las fuentes activas, con
///    `TVL ≥ minTvl`, ya medidas y sin APY sospechoso (mayor a `MAX_SANE_APY`).
///  - **Router:** `depositBest` deposita en la fuente de mejor score. El usuario recibe las
///    shares directamente y fija `minShares` como protección.
contract YieldAggregator is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    /// @notice Ventana mínima entre fotos (una ventana corta es fácil de manipular).
    uint256 public constant MIN_WINDOW = 1 hours;
    /// @notice APY por encima del cual una fuente se considera manipulada (200 %).
    uint256 public constant MAX_SANE_APY = 20_000;
    uint256 public constant MAX_SOURCES = 20;

    struct Source {
        IERC4626 vault;
        string name;
        uint16 riskBps; // 0 = sin riesgo, 10 000 = pérdida segura
        bool active;
        bool measured; // ya tiene al menos un APY calculado
        uint256 lastPps; // assets por 1 share entera
        uint64 lastTime;
        uint256 apyBps; // EMA del APY medido
    }

    /// @notice Fila del ranking (pensada para frontends y scripts).
    struct Row {
        uint256 id;
        string name;
        address vault;
        uint256 apyBps;
        uint256 riskBps;
        uint256 tvl;
        uint256 score;
        bool eligible;
    }

    IERC20 public immutable asset;
    uint256 public minTvl;
    Source[] internal _sources;

    event SourceAdded(uint256 indexed id, address vault, string name, uint16 riskBps);
    event SourceUpdated(uint256 indexed id, uint16 riskBps, bool active);
    event Poked(uint256 indexed id, uint256 pps, uint256 apyBps);
    event Routed(address indexed user, uint256 indexed id, uint256 assets, uint256 shares);

    error WrongAsset();
    error TooMany();
    error BadParam();
    error NoEligibleSource();
    error Slippage(uint256 got, uint256 min);

    constructor(IERC20 _asset, uint256 _minTvl) Ownable(msg.sender) {
        asset = _asset;
        minTvl = _minTvl;
    }

    // ------------------------------------------------------------------
    // Gobernanza
    // ------------------------------------------------------------------

    function addSource(IERC4626 v, string calldata name, uint16 riskBps) external onlyOwner returns (uint256 id) {
        if (v.asset() != address(asset)) revert WrongAsset();
        if (riskBps > BPS) revert BadParam();
        if (_sources.length >= MAX_SOURCES) revert TooMany();
        id = _sources.length;
        _sources.push(
            Source({
                vault: v,
                name: name,
                riskBps: riskBps,
                active: true,
                measured: false,
                lastPps: _pps(v),
                lastTime: uint64(block.timestamp),
                apyBps: 0
            })
        );
        emit SourceAdded(id, address(v), name, riskBps);
    }

    function setSource(uint256 id, uint16 riskBps, bool active) external onlyOwner {
        if (riskBps > BPS) revert BadParam();
        _sources[id].riskBps = riskBps;
        _sources[id].active = active;
        emit SourceUpdated(id, riskBps, active);
    }

    function setMinTvl(uint256 v) external onlyOwner {
        minTvl = v;
    }

    // ------------------------------------------------------------------
    // Medición (permisionless: cualquier keeper puede actualizar)
    // ------------------------------------------------------------------

    /// @notice Actualiza el APY de todas las fuentes cuya última foto tiene más de MIN_WINDOW.
    function poke() external {
        for (uint256 i; i < _sources.length; i++) _poke(i);
    }

    function _poke(uint256 id) internal {
        Source storage s = _sources[id];
        uint256 dt = block.timestamp - s.lastTime;
        if (dt < MIN_WINDOW) return;
        uint256 pps = _pps(s.vault);
        uint256 sample;
        if (pps > s.lastPps && s.lastPps > 0) {
            // apy = (pps/lastPps − 1) · año/dt  (interés simple anualizado, en bps)
            sample = ((pps - s.lastPps) * BPS * YEAR) / (s.lastPps * dt);
        }
        // pps que baja → sample 0 (pérdida: el APY medido cae)
        s.apyBps = s.measured ? (s.apyBps * 7 + sample * 3) / 10 : sample;
        s.measured = true;
        s.lastPps = pps;
        s.lastTime = uint64(block.timestamp);
        emit Poked(id, pps, s.apyBps);
    }

    // ------------------------------------------------------------------
    // Vistas
    // ------------------------------------------------------------------

    function sourceCount() external view returns (uint256) {
        return _sources.length;
    }

    function source(uint256 id) external view returns (Source memory) {
        return _sources[id];
    }

    /// @notice Calcula la fila de una fuente.
    function row(uint256 id) public view returns (Row memory r) {
        Source storage s = _sources[id];
        r.id = id;
        r.name = s.name;
        r.vault = address(s.vault);
        r.apyBps = s.apyBps;
        r.riskBps = s.riskBps;
        r.tvl = s.vault.totalAssets();
        r.score = (s.apyBps * (BPS - s.riskBps)) / BPS;
        r.eligible = s.active && s.measured && r.tvl >= minTvl && s.apyBps <= MAX_SANE_APY;
    }

    /// @notice Todas las fuentes ordenadas: elegibles primero, después por score descendente.
    function ranking() public view returns (Row[] memory rows) {
        uint256 n = _sources.length;
        rows = new Row[](n);
        for (uint256 i; i < n; i++) rows[i] = row(i);
        // insertion sort (n ≤ 20)
        for (uint256 i = 1; i < n; i++) {
            Row memory k = rows[i];
            uint256 j = i;
            while (j > 0 && _better(k, rows[j - 1])) {
                rows[j] = rows[j - 1];
                j--;
            }
            rows[j] = k;
        }
    }

    /// @notice Mejor fuente elegible (revierte si no hay ninguna).
    function best() public view returns (Row memory r) {
        Row[] memory rows = ranking();
        if (rows.length == 0 || !rows[0].eligible) revert NoEligibleSource();
        return rows[0];
    }

    // ------------------------------------------------------------------
    // Router
    // ------------------------------------------------------------------

    /// @notice Deposita `assets` del caller en la mejor fuente; las shares van a `receiver`.
    function depositBest(uint256 assets, address receiver, uint256 minShares)
        external
        nonReentrant
        returns (uint256 id, uint256 shares)
    {
        Row memory b = best();
        id = b.id;
        IERC4626 v = _sources[id].vault;
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(address(v), assets);
        shares = v.deposit(assets, receiver);
        asset.forceApprove(address(v), 0); // no dejar allowance colgado
        if (shares < minShares) revert Slippage(shares, minShares);
        emit Routed(receiver, id, assets, shares);
    }

    // ------------------------------------------------------------------
    // Internos
    // ------------------------------------------------------------------

    function _pps(IERC4626 v) internal view returns (uint256) {
        return v.convertToAssets(10 ** v.decimals());
    }

    function _better(Row memory a, Row memory b) internal pure returns (bool) {
        if (a.eligible != b.eligible) return a.eligible;
        return a.score > b.score;
    }
}
