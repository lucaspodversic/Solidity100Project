// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PriceOracle} from "./oracle/PriceOracle.sol";

/// @title OptionsMarket — opciones europeas call/put sobre ETH, liquidadas en efectivo
/// @notice Cada serie (tipo, strike, vencimiento) es un id ERC-1155. Modelo
///         "totalmente colateralizado" (estilo Opyn v1 / Hegic sin pool):
///   - **Call cubierta**: el lanzador (writer) deposita 1 WETH por opción.
///   - **Put asegurada en efectivo**: el lanzador deposita `strike` USDC por opción.
///   A cambio recibe los tokens de la opción, que vende (en un AMM/OTC, fuera de alcance) y
///   cobra la prima. Al vencimiento se toma el precio del oráculo (S) y:
///   - holder de call cobra max(S−K, 0)/S WETH por opción  (payoff en el subyacente)
///   - holder de put  cobra max(K−S, 0)   USDC por opción
///   - el lanzador recupera el colateral menos lo que se pagó a los holders.
///   Como el colateral cubre el peor caso, **nunca hay deuda incobrable** ni liquidaciones.
///
/// Unidades: 1e18 unidades de opción = 1 opción sobre 1 ETH. Strike y precios en USD WAD.
contract OptionsMarket is ERC1155, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    /// @dev USD WAD → USDC 6 decimales.
    uint256 internal constant TO_USDC = 1e12;
    /// @notice Ventana tras el vencimiento en la que cualquiera puede liquidar con el oráculo.
    uint256 public constant SETTLE_WINDOW = 1 hours;
    /// @notice Pasada la ventana, el owner puede fijar el precio (p.ej. el histórico de Chainlink).
    uint256 public constant MANUAL_DELAY = 1 days;

    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    PriceOracle public immutable oracle;

    struct Series {
        bool isCall;
        uint64 expiry;
        uint256 strike; // USD WAD
        bool exists;
        bool settled;
        uint256 settlementPrice; // USD WAD
        uint256 totalWritten; // unidades de opción con colateral vivo
    }

    mapping(uint256 => Series) public series;
    /// @notice Cuántas opciones lanzó cada writer en cada serie (su "posición corta").
    mapping(uint256 => mapping(address => uint256)) public written;

    event SeriesCreated(uint256 indexed id, bool isCall, uint256 strike, uint64 expiry);
    event Written(uint256 indexed id, address indexed writer, uint256 amount, uint256 collateral);
    event WriteClosed(uint256 indexed id, address indexed writer, uint256 amount);
    event Settled(uint256 indexed id, uint256 price, bool manual);
    event Exercised(uint256 indexed id, address indexed holder, uint256 amount, uint256 payout);
    event WriterRedeemed(uint256 indexed id, address indexed writer, uint256 amount, uint256 payout);

    error UnknownSeries();
    error BadParams();
    error Expired();
    error NotExpired();
    error AlreadySettled();
    error NotSettled();
    error WindowClosed();
    error TooEarlyForManual();
    error ZeroAmount();

    constructor(IERC20 weth_, IERC20 usdc_, PriceOracle oracle_) ERC1155("") Ownable(msg.sender) {
        weth = weth_;
        usdc = usdc_;
        oracle = oracle_;
    }

    // =====================================================================
    // Series
    // =====================================================================

    /// @notice Id determinístico de una serie: cualquiera puede calcularlo off-chain.
    function seriesId(bool isCall, uint256 strike, uint64 expiry) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(isCall, strike, expiry)));
    }

    /// @notice Crear series es libre (sin permisos): el colateral completo hace que una serie
    ///         "rara" no ponga en riesgo a nadie más que a quien la use.
    function createSeries(bool isCall, uint256 strike, uint64 expiry) external returns (uint256 id) {
        if (strike == 0 || expiry <= block.timestamp) revert BadParams();
        id = seriesId(isCall, strike, expiry);
        if (series[id].exists) revert BadParams();
        series[id] = Series(isCall, expiry, strike, true, false, 0, 0);
        emit SeriesCreated(id, isCall, strike, expiry);
    }

    // =====================================================================
    // Lanzadores (writers)
    // =====================================================================

    /// @notice Colateral necesario para lanzar `amount` opciones (redondeo hacia arriba).
    function collateralFor(uint256 id, uint256 amount) public view returns (uint256) {
        Series memory s = series[id];
        if (s.isCall) return amount; // 1 WETH (1e18) por opción (1e18)
        return Math.mulDiv(amount, s.strike, WAD * TO_USDC, Math.Rounding.Ceil);
    }

    /// @notice Deposita colateral y acuña `amount` opciones a `msg.sender`.
    function write(uint256 id, uint256 amount) external nonReentrant {
        Series storage s = _live(id);
        if (amount == 0) revert ZeroAmount();
        uint256 c = collateralFor(id, amount);
        (s.isCall ? weth : usdc).safeTransferFrom(msg.sender, address(this), c);
        written[id][msg.sender] += amount;
        s.totalWritten += amount;
        _mint(msg.sender, id, amount, "");
        emit Written(id, msg.sender, amount, c);
    }

    /// @notice Antes del vencimiento, el writer puede recomprar (quemar) opciones que tenga y
    ///         recuperar el colateral — es "cerrar" la posición corta.
    function closeWrite(uint256 id, uint256 amount) external nonReentrant {
        Series storage s = _live(id);
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, id, amount); // revierte si no tiene los tokens
        written[id][msg.sender] -= amount; // revierte si no los lanzó él
        s.totalWritten -= amount;
        // Se devuelve exactamente lo que costaría lanzarlas (redondeo hacia abajo para que el
        // ida-y-vuelta nunca extraiga polvo).
        uint256 c = s.isCall ? amount : Math.mulDiv(amount, s.strike, WAD * TO_USDC);
        (s.isCall ? weth : usdc).safeTransfer(msg.sender, c);
        emit WriteClosed(id, msg.sender, amount);
    }

    // =====================================================================
    // Liquidación (settlement)
    // =====================================================================

    /// @notice Fija el precio de liquidación con el oráculo. Solo en la ventana posterior al
    ///         vencimiento, para que el precio sea "el del vencimiento" y no uno elegido después.
    function settle(uint256 id) external {
        Series storage s = _expiredUnsettled(id);
        if (block.timestamp > s.expiry + SETTLE_WINDOW) revert WindowClosed();
        _settle(id, s, oracle.getPrice(address(weth)), false);
    }

    /// @notice Respaldo si nadie liquidó a tiempo (para que los fondos no queden trabados).
    function settleManual(uint256 id, uint256 price) external onlyOwner {
        Series storage s = _expiredUnsettled(id);
        if (block.timestamp < s.expiry + MANUAL_DELAY) revert TooEarlyForManual();
        if (price == 0) revert BadParams();
        _settle(id, s, price, true);
    }

    function _settle(uint256 id, Series storage s, uint256 price, bool manual) internal {
        s.settled = true;
        s.settlementPrice = price;
        emit Settled(id, price, manual);
    }

    // =====================================================================
    // Cobros
    // =====================================================================

    /// @notice Payoff de `amount` opciones para el holder (en WETH si call, USDC si put).
    function holderPayoff(uint256 id, uint256 amount) public view returns (uint256) {
        Series memory s = series[id];
        uint256 S = s.settlementPrice;
        if (s.isCall) {
            if (S <= s.strike) return 0;
            return Math.mulDiv(amount, S - s.strike, S); // fracción de 1 ETH por opción
        }
        if (S >= s.strike) return 0;
        return Math.mulDiv(amount, s.strike - S, WAD * TO_USDC);
    }

    /// @notice Lo que recupera el writer por `amount` opciones lanzadas: colateral − payoff.
    /// @dev Se calcula directamente (no como resta) y redondeando abajo: holders + writers ≤
    ///      colateral total siempre, así que el contrato es solvente al wei.
    function writerPayout(uint256 id, uint256 amount) public view returns (uint256) {
        Series memory s = series[id];
        uint256 S = s.settlementPrice;
        if (s.isCall) {
            if (S <= s.strike) return amount;
            return Math.mulDiv(amount, s.strike, S); // le queda K/S ETH por opción
        }
        uint256 kept = S >= s.strike ? s.strike : S; // le queda min(K, S) USDC por opción
        return Math.mulDiv(amount, kept, WAD * TO_USDC);
    }

    /// @notice El holder quema sus opciones y cobra el payoff.
    function exercise(uint256 id, uint256 amount) external nonReentrant returns (uint256 payout) {
        Series storage s = series[id];
        if (!s.settled) revert NotSettled();
        if (amount == 0) revert ZeroAmount();
        payout = holderPayoff(id, amount);
        _burn(msg.sender, id, amount);
        if (payout > 0) (s.isCall ? weth : usdc).safeTransfer(msg.sender, payout);
        emit Exercised(id, msg.sender, amount, payout);
    }

    /// @notice El writer retira lo que le queda de su colateral.
    function redeemWriter(uint256 id) external nonReentrant returns (uint256 payout) {
        Series storage s = series[id];
        if (!s.settled) revert NotSettled();
        uint256 amount = written[id][msg.sender];
        if (amount == 0) revert ZeroAmount();
        written[id][msg.sender] = 0;
        s.totalWritten -= amount;
        payout = writerPayout(id, amount);
        if (payout > 0) (s.isCall ? weth : usdc).safeTransfer(msg.sender, payout);
        emit WriterRedeemed(id, msg.sender, amount, payout);
    }

    // =====================================================================
    // Vistas de ayuda
    // =====================================================================

    /// @notice Valor intrínseco actual (USD WAD por opción) — útil para UIs; no es la prima.
    function intrinsicValue(uint256 id) external view returns (uint256) {
        Series memory s = series[id];
        uint256 S = oracle.getPrice(address(weth));
        if (s.isCall) return S > s.strike ? S - s.strike : 0;
        return s.strike > S ? s.strike - S : 0;
    }

    // ---------------------------------------------------------------------

    function _live(uint256 id) internal view returns (Series storage s) {
        s = series[id];
        if (!s.exists) revert UnknownSeries();
        if (block.timestamp >= s.expiry) revert Expired();
    }

    function _expiredUnsettled(uint256 id) internal view returns (Series storage s) {
        s = series[id];
        if (!s.exists) revert UnknownSeries();
        if (block.timestamp < s.expiry) revert NotExpired();
        if (s.settled) revert AlreadySettled();
    }
}
