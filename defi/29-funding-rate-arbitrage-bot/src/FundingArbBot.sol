// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PerpMarket} from "./perp/PerpMarket.sol";

/// @title FundingArbBot — arbitraje de funding entre dos perpetuos del mismo activo
/// @notice Si el venue A cobra a los longs un funding alto y el venue B uno bajo (o negativo),
///         el bot abre **short en A y long en B** por el mismo tamaño:
///           - Exposición al precio ≈ 0 (los dos legs usan el mismo subyacente).
///           - Cobra funding en A (como short del lado minoritario) y paga poco —o cobra—
///             en B. La ganancia es el *spread* de funding × notional × tiempo.
///         Cuando el spread converge (los propios arbitrajistas lo comprimen) se cierra todo.
///
/// Roles (separación de privilegios):
///   - `owner`: fondea/retira USDC y configura límites. Debería ser una multisig.
///   - `operator`: la key "caliente" del bot off-chain. Solo puede abrir/cerrar/rebalancear
///     DENTRO de los límites y **nunca** puede sacar fondos del contrato.
///   - cualquiera: puede cerrar si `shouldClose()` (spread muerto o un leg liquidado), así
///     un bot caído no deja una posición desnuda abierta.
///
/// Unidades: tasas de funding en fracción WAD **por día** (0.01e18 = 1 %/día), tamaños en
/// unidades base WAD, USDC con 6 decimales.
contract FundingArbBot is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;

    IERC20 public immutable usdc;
    PerpMarket public immutable venueA;
    PerpMarket public immutable venueB;

    address public operator;
    /// @notice Spread mínimo (por día) para abrir.
    int256 public entrySpreadPerDay = 0.002e18; // 0,2 %/día
    /// @notice Por debajo de este spread la posición ya no paga los costos: se cierra.
    int256 public exitSpreadPerDay = 0.0005e18; // 0,05 %/día
    /// @notice Tamaño máximo por leg (unidades base WAD).
    uint256 public maxSizePerLeg = 100e18;
    /// @notice Margen mínimo por leg como % del notional (3333 bps ≈ 3x de apalancamiento).
    uint256 public minMarginBps = 3_333;
    /// @notice Umbral de salud: si el equity de un leg cae bajo este % del notional, toca rebalancear.
    uint256 public rebalanceBps = 1_500;

    bool public isOpen;
    /// @notice true = short en A / long en B; false = al revés.
    bool public shortOnA;

    event OperatorSet(address operator);
    event ParamsSet(int256 entry, int256 exit, uint256 maxSize, uint256 minMarginBps, uint256 rebalanceBps);
    event Opened(bool shortOnA, uint256 size, uint256 marginPerLeg, int256 spreadBefore, int256 spreadAfter);
    event Closed(address indexed caller, uint256 usdcBack);
    event Rebalanced(bool fromA, uint256 amount);

    error NotAuthorized();
    error AlreadyOpen();
    error NotOpen();
    error SpreadTooLow(int256 spread);
    error SpreadTooLowAfter(int256 spread);
    error SizeTooLarge();
    error MarginTooLow();
    error PriceDeviation(uint256 price, uint256 refPrice);

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    constructor(IERC20 usdc_, PerpMarket a, PerpMarket b, address owner_, address operator_) Ownable(owner_) {
        require(address(a.usdc()) == address(usdc_) && address(b.usdc()) == address(usdc_), "usdc");
        require(a.baseAsset() == b.baseAsset(), "mismo activo");
        usdc = usdc_;
        venueA = a;
        venueB = b;
        operator = operator_;
        usdc_.forceApprove(address(a), type(uint256).max);
        usdc_.forceApprove(address(b), type(uint256).max);
    }

    // =====================================================================
    // Vistas de decisión (las usa el script/keeper off-chain)
    // =====================================================================

    /// @notice Spread de funding A − B por día. > 0 → conviene short A / long B.
    function spreadPerDay() public view returns (int256) {
        return venueA.fundingRatePerDay() - venueB.fundingRatePerDay();
    }

    /// @notice Spread "a favor" de la posición abierta (lo que se cobra neto por día y por
    ///         unidad de notional). Si es negativo, la posición pierde funding.
    function edgePerDay() public view returns (int256) {
        int256 s = spreadPerDay();
        return shortOnA ? s : -s;
    }

    /// @notice Edge (por día) que quedaría DESPUÉS de abrir `size`: nuestros trades achican el
    ///         skew de ambos venues, así que el spread observable antes de operar sobreestima
    ///         la ganancia. Replica la fórmula de funding del venue (lineal en skew y acotada).
    function previewEdge(uint256 size) public view returns (int256) {
        int256 s = spreadPerDay();
        int256 sz = size.toInt256();
        // short en el venue caro (su skew baja), long en el barato (su skew sube)
        (PerpMarket shortV, PerpMarket longV) = s > 0 ? (venueA, venueB) : (venueB, venueA);
        return _rateAfter(shortV, -sz) - _rateAfter(longV, sz);
    }

    /// @notice true si conviene abrir `size`: spread actual ≥ entrada y el edge posterior
    ///         sigue por encima del umbral de salida (misma regla que hace cumplir `open`).
    function shouldOpen(uint256 size) external view returns (bool) {
        if (isOpen) return false;
        int256 s = spreadPerDay();
        if ((s > 0 ? s : -s) < entrySpreadPerDay) return false;
        return previewEdge(size) >= exitSpreadPerDay;
    }

    /// @notice Cerrar es obligatorio si el spread murió o si un leg fue liquidado (el otro
    ///         quedó desnudo y expuesto al precio).
    function shouldClose() public view returns (bool) {
        if (!isOpen) return false;
        if (_legLiquidated()) return true;
        return edgePerDay() < exitSpreadPerDay;
    }

    /// @notice true si algún leg tiene equity bajo `rebalanceBps` del notional.
    function needsRebalance() external view returns (bool) {
        if (!isOpen || _legLiquidated()) return false;
        return _unhealthy(venueA) || _unhealthy(venueB);
    }

    /// @notice Valor total: USDC ociosos + equity de los dos legs (marcado al oráculo).
    function totalEquity() public view returns (int256 eq) {
        eq = int256(usdc.balanceOf(address(this)));
        eq += venueA.equity(address(this));
        eq += venueB.equity(address(this));
    }

    // =====================================================================
    // Operación
    // =====================================================================

    /// @notice Abre los dos legs por `size` con `marginPerLeg` USDC en cada venue.
    /// @param refPrice Precio que vio el bot off-chain; si el oráculo se movió más de
    ///        `maxDevBps` desde entonces, no se opera (protección de slippage).
    function open(uint256 size, uint256 marginPerLeg, uint256 refPrice, uint256 maxDevBps)
        external
        nonReentrant
        onlyOperator
    {
        if (isOpen) revert AlreadyOpen();
        if (size == 0 || size > maxSizePerLeg) revert SizeTooLarge();

        int256 spreadBefore = spreadPerDay();
        bool sA = spreadBefore > 0;
        if ((sA ? spreadBefore : -spreadBefore) < entrySpreadPerDay) revert SpreadTooLow(spreadBefore);

        // Slippage: mismo límite para ambos legs (los dos usan el mismo oráculo).
        uint256 px = venueA.price();
        uint256 dev = px > refPrice ? px - refPrice : refPrice - px;
        if (dev * BPS > refPrice * maxDevBps) revert PriceDeviation(px, refPrice);
        uint256 lo = refPrice * (BPS - maxDevBps) / BPS;
        uint256 hi = refPrice * (BPS + maxDevBps) / BPS;

        // Margen mínimo: limita el apalancamiento para aguantar movimientos de precio
        // mientras un leg pierde y el otro gana (el margen NO se compensa entre venues).
        uint256 notionalUsdc = size * px / 1e18 / 1e12;
        if (marginPerLeg * BPS < notionalUsdc * minMarginBps) revert MarginTooLow();

        (PerpMarket shortV, PerpMarket longV) = sA ? (venueA, venueB) : (venueB, venueA);
        shortV.depositMargin(marginPerLeg);
        longV.depositMargin(marginPerLeg);
        int256 s = size.toInt256();
        shortV.trade(-s, lo);
        longV.trade(s, hi);

        isOpen = true;
        shortOnA = sA;

        // Nuestros propios trades comprimen el spread (achican el skew de los dos venues).
        // Si el tamaño era tan grande que el spread resultante ya no cubre ni el umbral de
        // salida, el trade no tiene sentido económico: revertimos todo.
        int256 after_ = edgePerDay();
        if (after_ < exitSpreadPerDay) revert SpreadTooLowAfter(after_);
        emit Opened(sA, size, marginPerLeg, spreadBefore, after_);
    }

    /// @notice Cierra ambos legs y trae todo el margen de vuelta.
    ///         Operador/owner: siempre. Cualquier otro: solo si `shouldClose()`.
    function close() external nonReentrant returns (uint256 usdcBack) {
        if (!isOpen) revert NotOpen();
        if (msg.sender != operator && msg.sender != owner() && !shouldClose()) revert NotAuthorized();
        uint256 before = usdc.balanceOf(address(this));
        _closeLeg(venueA);
        _closeLeg(venueB);
        isOpen = false;
        usdcBack = usdc.balanceOf(address(this)) - before;
        emit Closed(msg.sender, usdcBack);
    }

    /// @notice Mueve margen del leg ganador al perdedor (el margen está aislado por venue,
    ///         así que una suba fuerte puede liquidar el short aunque el total esté bien).
    function rebalance(bool fromA, uint256 amount) external nonReentrant onlyOperator {
        if (!isOpen) revert NotOpen();
        (PerpMarket from, PerpMarket to) = fromA ? (venueA, venueB) : (venueB, venueA);
        from.withdrawMargin(amount); // el venue exige que `from` siga sobre el margen inicial
        to.depositMargin(amount);
        emit Rebalanced(fromA, amount);
    }

    // =====================================================================
    // Owner
    // =====================================================================

    function withdraw(address to, uint256 amount) external onlyOwner {
        usdc.safeTransfer(to, amount);
    }

    function setOperator(address op) external onlyOwner {
        operator = op;
        emit OperatorSet(op);
    }

    function setParams(int256 entry, int256 exit, uint256 maxSize, uint256 minMargin, uint256 rebal)
        external
        onlyOwner
    {
        require(entry > exit && exit >= 0 && minMargin >= 1_000 && minMargin <= BPS, "params");
        entrySpreadPerDay = entry;
        exitSpreadPerDay = exit;
        maxSizePerLeg = maxSize;
        minMarginBps = minMargin;
        rebalanceBps = rebal;
        emit ParamsSet(entry, exit, maxSize, minMargin, rebal);
    }

    // =====================================================================
    // Internos
    // =====================================================================

    function _closeLeg(PerpMarket v) internal {
        if (v.positionOf(address(this)).size != 0) {
            // Sin límite de precio al cerrar: salir es prioritario y el otro leg compensa.
            int256 sz = v.positionOf(address(this)).size;
            v.closePosition(sz > 0 ? 0 : type(uint256).max);
        }
        int256 m = v.margin(address(this));
        if (m > 0) v.withdrawMargin(uint256(m));
    }

    /// @dev Tasa por día que tendría `v` si su skew cambiara en `delta`.
    function _rateAfter(PerpMarket v, int256 delta) internal view returns (int256 r) {
        int256 maxR = v.maxFundingRatePerSecond();
        r = maxR * (v.skew() + delta) / v.skewScale();
        if (r > maxR) r = maxR;
        if (r < -maxR) r = -maxR;
        r *= 1 days;
    }

    function _legLiquidated() internal view returns (bool) {
        return venueA.positionOf(address(this)).size == 0 || venueB.positionOf(address(this)).size == 0;
    }

    function _unhealthy(PerpMarket v) internal view returns (bool) {
        return v.equity(address(this)) * int256(BPS) < int256(v.notional(address(this)) * rebalanceBps);
    }
}
