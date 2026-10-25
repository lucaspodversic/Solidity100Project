// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PriceOracle} from "./oracle/PriceOracle.sol";

/// @title PerpMarket — futuro perpetuo de un solo mercado (p.ej. ETH-USD) con margen en USDC
/// @notice Diseño "pool como contraparte" (estilo GMX / Synthetix Perps v2):
///   - Los traders abren long/short al precio del oráculo (sin libro de órdenes).
///   - Un pool de LPs en USDC es la contraparte del *skew* neto: si hay más longs que
///     shorts, el pool queda short por la diferencia y gana cuando los traders pierden.
///   - **Funding basado en skew**: el lado mayoritario paga al pool (que a su vez está del
///     lado minoritario neto). Eso incentiva a que alguien abra en el lado contrario y
///     equilibre el mercado — el arbitraje de funding del proyecto 29 vive de esto.
///   - Margen inicial / de mantenimiento, liquidaciones con premio al liquidador y un
///     **fondo de seguro** que absorbe la deuda incobrable antes que los LPs.
///
/// Unidades:
///   - `size`: unidades del activo base en WAD (1e18 = 1 ETH). Positivo = long, negativo = short.
///   - Precios y valores en USD: WAD. El margen y la caja se guardan en USDC (6 decimales).
///   - `fundingIndex`: USD (WAD) acumulados que paga 1 unidad long desde el deploy.
///
/// Toda la contabilidad agregada es O(1): con `netSize`, Σ(size·entry) y Σ(size·fundingEntry)
/// se obtiene el PnL y el funding no realizados de *todos* los traders sin iterar.
contract PerpMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ---------------------------------------------------------------------
    // Constantes y parámetros
    // ---------------------------------------------------------------------
    int256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev USD en WAD → USDC (6 decimales).
    int256 internal constant TO_USDC = 1e12;

    IERC20 public immutable usdc;
    PriceOracle public immutable oracle;
    /// @notice Clave del activo base en el oráculo (p.ej. la dirección de WETH).
    address public immutable baseAsset;

    /// @notice Funding máximo por segundo (fracción WAD del notional) cuando |skew| ≥ skewScale.
    int256 public maxFundingRatePerSecond;
    /// @notice Skew (en unidades base WAD) al cual el funding llega a su máximo.
    int256 public skewScale;

    uint256 public initialMarginBps = 1_000; // 10 % → apalancamiento máximo 10x
    uint256 public maintenanceMarginBps = 500; // 5 %
    uint256 public liquidationFeeBps = 100; // 1 % del notional para el liquidador
    uint256 public tradingFeeBps = 5; // 0,05 % del notional por trade
    uint256 public insuranceShareBps = 2_000; // 20 % de las fees va al fondo de seguro
    /// @notice |skew|·precio no puede superar este % del valor del pool (riesgo de los LPs).
    uint256 public maxSkewToPoolBps = 10_000;

    // ---------------------------------------------------------------------
    // Estado
    // ---------------------------------------------------------------------
    struct Position {
        int256 size; // WAD base, + long / − short
        uint256 entryPrice; // WAD
        int256 fundingEntry; // fundingIndex al último settle
    }

    mapping(address => Position) internal _positions;
    /// @notice Margen de cada trader en USDC. Es int porque una pérdida puede dejarlo
    ///         transitoriamente negativo durante una liquidación (deuda incobrable).
    mapping(address => int256) public margin;

    int256 public fundingIndex;
    uint256 public lastFundingTime;

    uint256 public longOI; // Σ size de longs (WAD)
    uint256 public shortOI; // Σ |size| de shorts (WAD)
    int256 internal _sumSizeEntry; // Σ size·entry / WAD   (USD WAD)
    int256 internal _sumSizeFunding; // Σ size·fundingEntry / WAD (USD WAD)

    /// @notice Caja de los LPs (USDC). Su valor real es `poolValue()` (incluye PnL abierto).
    int256 public lpCash;
    uint256 public insuranceFund;
    mapping(address => uint256) public lpShares;
    uint256 public totalLpShares;

    // ---------------------------------------------------------------------
    // Eventos y errores
    // ---------------------------------------------------------------------
    event MarginDeposited(address indexed account, uint256 amount);
    event MarginWithdrawn(address indexed account, uint256 amount);
    event Trade(address indexed account, int256 sizeDelta, uint256 price, int256 realizedPnl, uint256 fee);
    event Liquidated(address indexed account, address indexed liquidator, int256 size, uint256 price, uint256 reward, uint256 badDebt);
    event FundingAccrued(int256 rate, int256 index);
    event LpDeposit(address indexed lp, uint256 amount, uint256 shares);
    event LpWithdraw(address indexed lp, uint256 amount, uint256 shares);

    error ZeroAmount();
    error PriceSlippage(uint256 price, uint256 acceptable);
    error InsufficientMargin(int256 equity, uint256 required);
    error NotLiquidatable();
    error SkewCapExceeded();
    error NoPosition();
    error InsufficientPoolLiquidity();

    constructor(IERC20 usdc_, PriceOracle oracle_, address baseAsset_, int256 maxFundingPerDay, int256 skewScale_)
        Ownable(msg.sender)
    {
        usdc = usdc_;
        oracle = oracle_;
        baseAsset = baseAsset_;
        maxFundingRatePerSecond = maxFundingPerDay / 1 days;
        skewScale = skewScale_;
        lastFundingTime = block.timestamp;
    }

    // =====================================================================
    // Funding
    // =====================================================================

    /// @notice Skew neto = longs − shorts (WAD base).
    function skew() public view returns (int256) {
        return longOI.toInt256() - shortOI.toInt256();
    }

    /// @notice Tasa de funding por segundo (fracción WAD del notional).
    ///         > 0: los longs pagan; < 0: los shorts pagan. Lineal en el skew y acotada.
    function currentFundingRate() public view returns (int256 r) {
        r = (maxFundingRatePerSecond * skew()) / skewScale;
        if (r > maxFundingRatePerSecond) r = maxFundingRatePerSecond;
        if (r < -maxFundingRatePerSecond) r = -maxFundingRatePerSecond;
    }

    /// @notice Lo mismo expresado por día (más legible para bots y UIs).
    function fundingRatePerDay() external view returns (int256) {
        return currentFundingRate() * 1 days;
    }

    /// @notice Índice de funding proyectado a `block.timestamp` (sin escribir).
    function pendingFundingIndex() public view returns (int256) {
        uint256 dt = block.timestamp - lastFundingTime;
        if (dt == 0) return fundingIndex;
        int256 price = _price().toInt256();
        return fundingIndex + (currentFundingRate() * price * dt.toInt256()) / WAD;
    }

    /// @notice Persiste el funding acumulado. Se llama al principio de toda acción que
    ///         cambie el skew, para que cada intervalo use la tasa que le correspondía.
    function accrueFunding() public {
        if (block.timestamp == lastFundingTime) return;
        fundingIndex = pendingFundingIndex();
        lastFundingTime = block.timestamp;
        emit FundingAccrued(currentFundingRate(), fundingIndex);
    }

    // =====================================================================
    // Margen
    // =====================================================================

    function depositMargin(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        margin[msg.sender] += amount.toInt256();
        emit MarginDeposited(msg.sender, amount);
    }

    /// @notice Retira margen libre. Con posición abierta, el equity restante debe cubrir el
    ///         margen inicial (no el de mantenimiento: si no, quedaría al borde de liquidación).
    function withdrawMargin(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        accrueFunding();
        Position storage p = _positions[msg.sender];
        _settleFunding(msg.sender, p);
        margin[msg.sender] -= amount.toInt256();
        if (margin[msg.sender] < 0) revert InsufficientMargin(margin[msg.sender], 0);
        if (p.size != 0) _requireMargin(msg.sender, initialMarginBps);
        usdc.safeTransfer(msg.sender, amount);
        emit MarginWithdrawn(msg.sender, amount);
    }

    // =====================================================================
    // Trading
    // =====================================================================

    /// @notice Abre, aumenta, reduce o da vuelta la posición en `sizeDelta`.
    /// @param acceptablePrice Protección de slippage: compras (delta>0) exigen precio ≤ límite,
    ///        ventas (delta<0) exigen precio ≥ límite. Defiende contra un oráculo que se movió
    ///        entre que el usuario firmó y que la tx se minó.
    function trade(int256 sizeDelta, uint256 acceptablePrice) external nonReentrant {
        if (sizeDelta == 0) revert ZeroAmount();
        _trade(msg.sender, sizeDelta, acceptablePrice);
    }

    /// @notice Cierra la posición completa.
    function closePosition(uint256 acceptablePrice) external nonReentrant {
        int256 size = _positions[msg.sender].size;
        if (size == 0) revert NoPosition();
        _trade(msg.sender, -size, acceptablePrice);
    }

    function _trade(address account, int256 sizeDelta, uint256 acceptablePrice) internal {
        accrueFunding();
        uint256 price = _price();
        if (sizeDelta > 0 ? price > acceptablePrice : price < acceptablePrice) {
            revert PriceSlippage(price, acceptablePrice);
        }

        Position storage p = _positions[account];
        _settleFunding(account, p);

        int256 skewBefore = skew();
        int256 realized = _applySizeChange(account, p, sizeDelta, price);

        // Fee sobre el notional operado: 80 % LPs, 20 % fondo de seguro.
        uint256 fee = (_abs(sizeDelta) * price / uint256(WAD)) * tradingFeeBps / BPS / uint256(TO_USDC);
        margin[account] -= fee.toInt256();
        uint256 toInsurance = fee * insuranceShareBps / BPS;
        insuranceFund += toInsurance;
        lpCash += (fee - toInsurance).toInt256();

        // El margen no puede quedar negativo por un trade voluntario.
        if (margin[account] < 0) revert InsufficientMargin(margin[account], 0);
        // Si la posición sigue abierta, tiene que respetar el margen inicial… salvo que el
        // trade solo la haya reducido (reducir riesgo siempre tiene que estar permitido).
        int256 oldSize = p.size - sizeDelta;
        bool flipped = oldSize != 0 && p.size != 0 && (oldSize > 0) != (p.size > 0);
        if (p.size != 0 && (_abs(p.size) > _abs(oldSize) || flipped)) {
            _requireMargin(account, initialMarginBps);
        }
        // El skew no puede crecer más allá de lo que el pool puede respaldar.
        int256 skewAfter = skew();
        if (_abs(skewAfter) > _abs(skewBefore)) _checkSkewCap(price);

        emit Trade(account, sizeDelta, price, realized, fee);
    }

    /// @dev Núcleo: actualiza tamaño, precio de entrada promedio, PnL realizado y agregados.
    function _applySizeChange(address account, Position storage p, int256 delta, uint256 price)
        internal
        returns (int256 realizedUsdc)
    {
        int256 oldSize = p.size;
        int256 newSize = oldSize + delta;
        _removeAggregates(p);

        if (oldSize == 0 || (oldSize > 0) == (delta > 0)) {
            // Aumenta en la misma dirección: precio de entrada promedio ponderado.
            p.entryPrice = (_abs(oldSize) * p.entryPrice + _abs(delta) * price) / _abs(newSize);
        } else {
            // Reduce (y quizá da vuelta): realiza el PnL de la parte cerrada.
            uint256 closing = _abs(delta) < _abs(oldSize) ? _abs(delta) : _abs(oldSize);
            int256 dir = oldSize > 0 ? int256(1) : int256(-1);
            int256 pnlWad = dir * closing.toInt256() * (price.toInt256() - p.entryPrice.toInt256()) / WAD;
            realizedUsdc = _toUsdcFloor(pnlWad);
            margin[account] += realizedUsdc;
            lpCash -= realizedUsdc;
            if (newSize == 0) p.entryPrice = 0;
            else if ((newSize > 0) != (oldSize > 0)) p.entryPrice = price; // flip: entra el remanente al precio actual
        }
        p.size = newSize;
        _addAggregates(p);
    }

    /// @dev Cobra/paga el funding acumulado desde el último settle. El pool es la contraparte.
    function _settleFunding(address account, Position storage p) internal {
        if (p.size != 0) {
            int256 owedWad = p.size * (fundingIndex - p.fundingEntry) / WAD; // > 0: el trader debe
            int256 delta = _toUsdcFloor(-owedWad);
            margin[account] += delta;
            lpCash -= delta;
        }
        // Actualizamos el agregado restando la contribución vieja y sumando la nueva con la
        // MISMA fórmula que _add/_removeAggregates, para que no se acumule error de redondeo.
        _sumSizeFunding -= p.size * p.fundingEntry / WAD;
        p.fundingEntry = fundingIndex;
        _sumSizeFunding += p.size * p.fundingEntry / WAD;
    }

    function _removeAggregates(Position storage p) internal {
        if (p.size > 0) longOI -= uint256(p.size);
        else shortOI -= uint256(-p.size);
        _sumSizeEntry -= p.size * p.entryPrice.toInt256() / WAD;
        _sumSizeFunding -= p.size * p.fundingEntry / WAD;
    }

    function _addAggregates(Position storage p) internal {
        if (p.size > 0) longOI += uint256(p.size);
        else shortOI += uint256(-p.size);
        _sumSizeEntry += p.size * p.entryPrice.toInt256() / WAD;
        _sumSizeFunding += p.size * p.fundingEntry / WAD;
    }

    // =====================================================================
    // Liquidaciones
    // =====================================================================

    /// @notice Equity del trader en USDC: margen + PnL no realizado − funding pendiente.
    function equity(address account) public view returns (int256) {
        Position memory p = _positions[account];
        int256 eq = margin[account];
        if (p.size == 0) return eq;
        uint256 price = _price();
        int256 pnl = p.size * (price.toInt256() - p.entryPrice.toInt256()) / WAD;
        int256 owed = p.size * (pendingFundingIndex() - p.fundingEntry) / WAD;
        return eq + _toUsdcFloor(pnl - owed);
    }

    /// @notice Notional de la posición a precio actual (USDC).
    function notional(address account) public view returns (uint256) {
        return _abs(_positions[account].size) * _price() / uint256(WAD) / uint256(TO_USDC);
    }

    function isLiquidatable(address account) public view returns (bool) {
        if (_positions[account].size == 0) return false;
        return equity(account) < (notional(account) * maintenanceMarginBps / BPS).toInt256();
    }

    /// @notice Precio de liquidación aproximado (ignora fees y funding futuro).
    function liquidationPrice(address account) external view returns (uint256) {
        Position memory p = _positions[account];
        if (p.size == 0) return 0;
        // En USD WAD: equity(P) = m + s·(P − E)/W  y la condición es equity = mm·|s|·P/W².
        // Despejando: P = (s·E − m·W) / (s − mm·|s|/W). Acá usamos numerador y denominador
        // con el signo invertido (mismo cociente).
        int256 m = (margin[account] * TO_USDC) - p.size * (pendingFundingIndex() - p.fundingEntry) / WAD;
        int256 s = p.size;
        int256 mm = int256(maintenanceMarginBps) * WAD / int256(BPS);
        int256 num = m * WAD - s * p.entryPrice.toInt256();
        int256 den = mm * _abs(s).toInt256() / WAD - s;
        if (den == 0) return 0;
        int256 px = num / den;
        return px > 0 ? uint256(px) : 0;
    }

    /// @notice Cualquiera puede liquidar una cuenta por debajo del margen de mantenimiento.
    ///         Se cierra todo al precio del oráculo, el liquidador cobra `liquidationFeeBps`
    ///         (limitado al equity que quede), el resto va al fondo de seguro y si hay deuda
    ///         incobrable la cubre primero el seguro y después los LPs.
    function liquidate(address account) external nonReentrant returns (uint256 reward) {
        accrueFunding();
        if (!isLiquidatable(account)) revert NotLiquidatable();
        Position storage p = _positions[account];
        uint256 price = _price();
        int256 size = p.size;
        uint256 notionalUsdc = notional(account);

        _settleFunding(account, p);
        _applySizeChange(account, p, -size, price);

        int256 eq = margin[account];
        margin[account] = 0;
        uint256 badDebt;
        if (eq > 0) {
            reward = notionalUsdc * liquidationFeeBps / BPS;
            if (reward > uint256(eq)) reward = uint256(eq);
            insuranceFund += uint256(eq) - reward;
        } else if (eq < 0) {
            badDebt = uint256(-eq);
            uint256 fromInsurance = badDebt < insuranceFund ? badDebt : insuranceFund;
            insuranceFund -= fromInsurance;
            lpCash -= (badDebt - fromInsurance).toInt256();
        }
        if (reward > 0) usdc.safeTransfer(msg.sender, reward);
        emit Liquidated(account, msg.sender, size, price, reward, badDebt);
    }

    // =====================================================================
    // Pool de LPs (contraparte)
    // =====================================================================

    /// @notice Valor del pool: caja − (PnL abierto de los traders − funding que deben).
    function poolValue() public view returns (int256) {
        int256 net = skew();
        int256 price = _price().toInt256();
        int256 tradersPnl = net * price / WAD - _sumSizeEntry;
        int256 tradersOwed = net * pendingFundingIndex() / WAD - _sumSizeFunding;
        return lpCash + _toUsdcFloor(-(tradersPnl - tradersOwed)); // redondeo conservador
    }

    /// @notice Depósito de LP. Shares virtuales (offset 1e6) contra el ataque de inflación.
    function lpDeposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        accrueFunding();
        int256 pv = poolValue();
        uint256 value = pv > 0 ? uint256(pv) : 0;
        shares = amount * (totalLpShares + 1e6) / (value + 1);
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        lpCash += amount.toInt256();
        lpShares[msg.sender] += shares;
        totalLpShares += shares;
        emit LpDeposit(msg.sender, amount, shares);
    }

    /// @notice Retiro de LP a valor de pool. No puede dejar el skew sin respaldo.
    function lpWithdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        accrueFunding();
        int256 pv = poolValue();
        uint256 value = pv > 0 ? uint256(pv) : 0;
        amount = shares * (value + 1) / (totalLpShares + 1e6);
        if (amount.toInt256() > lpCash) revert InsufficientPoolLiquidity();
        lpShares[msg.sender] -= shares;
        totalLpShares -= shares;
        lpCash -= amount.toInt256();
        _checkSkewCap(_price());
        usdc.safeTransfer(msg.sender, amount);
        emit LpWithdraw(msg.sender, amount, shares);
    }

    // =====================================================================
    // Admin y vistas
    // =====================================================================

    function setMarginParams(uint256 im, uint256 mm, uint256 liqFee) external onlyOwner {
        require(mm < im && im <= 5_000 && liqFee < mm, "params");
        initialMarginBps = im;
        maintenanceMarginBps = mm;
        liquidationFeeBps = liqFee;
    }

    function setFundingParams(int256 maxFundingPerDay, int256 skewScale_) external onlyOwner {
        require(skewScale_ > 0 && maxFundingPerDay >= 0, "params");
        accrueFunding(); // el intervalo previo se cobra con los parámetros viejos
        maxFundingRatePerSecond = maxFundingPerDay / 1 days;
        skewScale = skewScale_;
    }

    function setTradingFee(uint256 bps) external onlyOwner {
        require(bps <= 100, "fee");
        tradingFeeBps = bps;
    }

    function setMaxSkewToPool(uint256 bps) external onlyOwner {
        maxSkewToPoolBps = bps;
    }

    function positionOf(address account) external view returns (Position memory) {
        return _positions[account];
    }

    function price() external view returns (uint256) {
        return _price();
    }

    // ---------------------------------------------------------------------
    // Internos
    // ---------------------------------------------------------------------

    function _price() internal view returns (uint256) {
        return oracle.getPrice(baseAsset);
    }

    function _requireMargin(address account, uint256 bps) internal view {
        int256 eq = equity(account);
        uint256 required = notional(account) * bps / BPS;
        if (eq < required.toInt256()) revert InsufficientMargin(eq, required);
    }

    function _checkSkewCap(uint256 price_) internal view {
        uint256 skewUsd = _abs(skew()) * price_ / uint256(WAD) / uint256(TO_USDC);
        int256 pv = poolValue();
        uint256 value = pv > 0 ? uint256(pv) : 0;
        if (skewUsd > value * maxSkewToPoolBps / BPS) revert SkewCapExceeded();
    }

    /// @dev USD WAD → USDC redondeando hacia −∞ (siempre a favor del pool).
    function _toUsdcFloor(int256 wad) internal pure returns (int256 q) {
        q = wad / TO_USDC;
        if (wad < 0 && wad % TO_USDC != 0) q -= 1;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
