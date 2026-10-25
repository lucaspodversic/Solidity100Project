// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";

/// @title ConcentratedPool — DEX de liquidez concentrada estilo Uniswap V3 (simplificado)
/// @notice Los LP eligen un rango de precio [tickLower, tickUpper) y su liquidez solo trabaja
///         (y cobra comisiones) mientras el precio esté dentro de ese rango. Esto multiplica
///         la eficiencia del capital frente a x·y=k, a cambio de mayor riesgo de quedar
///         "fuera de rango" (100 % en un solo token, sin cobrar comisiones).
/// @dev Simplificaciones frente a V3 (documentadas en el README):
///        - Ticks inicializados en un arreglo ordenado (no bitmap) => O(n) al insertar.
///        - Sin oráculo de observaciones ni protocol fee.
///        - Posiciones identificadas por (owner, lower, upper), sin NFT.
///        - Pago por `transferFrom` (requiere approve) en lugar de callbacks.
contract ConcentratedPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice 2^128, escala de los acumuladores de comisión por unidad de liquidez.
    uint256 internal constant Q128 = 2 ** 128;
    /// @notice Denominador de la comisión (partes por millón).
    uint24 internal constant FEE_DEN = 1_000_000;

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    /// @notice Comisión en ppm (3000 = 0,3 %).
    uint24 public immutable fee;
    /// @notice Solo se pueden usar ticks múltiplos de este valor (reduce fragmentación y gas).
    int24 public immutable tickSpacing;

    /// @notice Raíz del precio actual (token1 por token0) en Q64.96.
    uint160 public sqrtPriceX96;
    /// @notice Tick actual: mayor t con sqrtAt(t) <= sqrtPriceX96.
    int24 public tick;
    /// @notice Liquidez activa (suma de posiciones cuyo rango contiene al precio).
    uint128 public liquidity;

    /// @notice Comisiones acumuladas por unidad de liquidez desde el inicio (Q128).
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    /// @notice Estado por tick inicializado.
    struct TickInfo {
        uint128 liquidityGross; // liquidez total que referencia este tick (para saber si borrarlo)
        int128 liquidityNet; // cuánto cambia la liquidez activa al cruzarlo de izquierda a derecha
        uint256 feeGrowthOutside0X128; // comisiones acumuladas "del otro lado" del tick
        uint256 feeGrowthOutside1X128;
    }

    /// @notice Estado de una posición de un LP.
    struct Position {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128; // snapshot para calcular comisiones nuevas
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0; // comisiones + principal retirado pendiente de `collect`
        uint128 tokensOwed1;
    }

    mapping(int24 => TickInfo) public ticks;
    mapping(bytes32 => Position) public positions;
    /// @dev Ticks inicializados en orden ascendente.
    int24[] internal initializedTicks;

    event Initialize(uint160 sqrtPriceX96, int24 tick);
    event Mint(address indexed owner, int24 tickLower, int24 tickUpper, uint128 amount, uint256 amount0, uint256 amount1);
    event Burn(address indexed owner, int24 tickLower, int24 tickUpper, uint128 amount, uint256 amount0, uint256 amount1);
    event Collect(address indexed owner, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);
    event Swap(
        address indexed sender, address indexed recipient, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceX96, int24 tick
    );

    error AlreadyInitialized();
    error NotInitialized();
    error InvalidTicks();
    error ZeroLiquidity();
    error InvalidPriceLimit();
    error InsufficientOutput();
    error ZeroAmount();

    constructor(IERC20 _token0, IERC20 _token1, uint24 _fee, int24 _tickSpacing) {
        require(address(_token0) < address(_token1), "orden de tokens");
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
    }

    /// @notice Fija el precio inicial del pool. Una sola vez.
    function initialize(uint160 _sqrtPriceX96) external {
        if (sqrtPriceX96 != 0) revert AlreadyInitialized();
        tick = TickMath.getTickAtSqrtPrice(_sqrtPriceX96);
        sqrtPriceX96 = _sqrtPriceX96;
        emit Initialize(_sqrtPriceX96, tick);
    }

    /// @notice Clave de una posición.
    function positionKey(address owner, int24 lower, int24 upper) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, lower, upper));
    }

    /// @notice Lista de ticks inicializados (para lectura off-chain).
    function getInitializedTicks() external view returns (int24[] memory) {
        return initializedTicks;
    }

    // ------------------------------------------------------------------
    // Liquidez
    // ------------------------------------------------------------------

    /// @notice Agrega `amount` de liquidez en [lower, upper) y cobra los tokens necesarios.
    /// @return amount0 Token0 aportado.
    /// @return amount1 Token1 aportado.
    function mint(int24 lower, int24 upper, uint128 amount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (amount == 0) revert ZeroLiquidity();
        (amount0, amount1) = _modifyPosition(msg.sender, lower, upper, int128(amount));
        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
        emit Mint(msg.sender, lower, upper, amount, amount0, amount1);
    }

    /// @notice Quita liquidez. Los tokens quedan "owed" y se retiran con `collect`.
    function burn(int24 lower, int24 upper, uint128 amount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _modifyPosition(msg.sender, lower, upper, -int128(amount));
        Position storage p = positions[positionKey(msg.sender, lower, upper)];
        p.tokensOwed0 += uint128(amount0);
        p.tokensOwed1 += uint128(amount1);
        emit Burn(msg.sender, lower, upper, amount, amount0, amount1);
    }

    /// @notice Retira principal quemado + comisiones acumuladas.
    /// @dev Llamar `burn(…, 0)` antes actualiza las comisiones sin quitar liquidez ("poke").
    function collect(int24 lower, int24 upper, uint128 max0, uint128 max1)
        external
        nonReentrant
        returns (uint128 a0, uint128 a1)
    {
        Position storage p = positions[positionKey(msg.sender, lower, upper)];
        a0 = max0 > p.tokensOwed0 ? p.tokensOwed0 : max0;
        a1 = max1 > p.tokensOwed1 ? p.tokensOwed1 : max1;
        p.tokensOwed0 -= a0;
        p.tokensOwed1 -= a1;
        if (a0 > 0) token0.safeTransfer(msg.sender, a0);
        if (a1 > 0) token1.safeTransfer(msg.sender, a1);
        emit Collect(msg.sender, lower, upper, a0, a1);
    }

    /// @dev Núcleo de mint/burn: actualiza ticks, comisiones de la posición, liquidez activa
    ///      y calcula los montos según dónde está el precio respecto del rango.
    function _modifyPosition(address owner, int24 lower, int24 upper, int128 delta)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceX96 == 0) revert NotInitialized();
        if (
            lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % tickSpacing != 0
                || upper % tickSpacing != 0
        ) revert InvalidTicks();

        _updateTick(lower, delta, false);
        _updateTick(upper, delta, true);

        // Comisiones de la posición hasta ahora (antes de cambiar su liquidez).
        (uint256 in0, uint256 in1) = _feeGrowthInside(lower, upper);
        Position storage p = positions[positionKey(owner, lower, upper)];
        unchecked {
            // Las restas de acumuladores son modulares a propósito (pueden "dar la vuelta").
            p.tokensOwed0 += uint128(Math.mulDiv(in0 - p.feeGrowthInside0LastX128, p.liquidity, Q128));
            p.tokensOwed1 += uint128(Math.mulDiv(in1 - p.feeGrowthInside1LastX128, p.liquidity, Q128));
        }
        p.feeGrowthInside0LastX128 = in0;
        p.feeGrowthInside1LastX128 = in1;
        p.liquidity = _addDelta(p.liquidity, delta);

        // Si quedaron en cero, limpiamos los ticks (reembolso de gas y búsqueda más corta).
        if (ticks[lower].liquidityGross == 0) _removeTick(lower);
        if (ticks[upper].liquidityGross == 0) _removeTick(upper);

        uint160 sL = TickMath.getSqrtPriceAtTick(lower);
        uint160 sU = TickMath.getSqrtPriceAtTick(upper);
        uint128 absDelta = uint128(delta >= 0 ? delta : -delta);
        bool up = delta > 0; // al depositar redondeamos hacia arriba (a favor del pool)

        if (tick < lower) {
            // Precio por debajo del rango: la posición es 100 % token0.
            amount0 = LiquidityMath.amount0Delta(sL, sU, absDelta, up);
        } else if (tick < upper) {
            // Dentro del rango: ambos tokens y la liquidez pasa a estar activa.
            amount0 = LiquidityMath.amount0Delta(sqrtPriceX96, sU, absDelta, up);
            amount1 = LiquidityMath.amount1Delta(sL, sqrtPriceX96, absDelta, up);
            liquidity = _addDelta(liquidity, delta);
        } else {
            // Por encima: 100 % token1.
            amount1 = LiquidityMath.amount1Delta(sL, sU, absDelta, up);
        }
    }

    /// @dev Suma un delta con signo a una liquidez sin signo (revierte en underflow).
    function _addDelta(uint128 x, int128 d) internal pure returns (uint128) {
        return d < 0 ? x - uint128(-d) : x + uint128(d);
    }

    /// @dev Actualiza el tick y lo inicializa si es la primera vez que se lo referencia.
    ///      Convención V3: al inicializar, si el tick está por debajo del precio actual,
    ///      asumimos que TODA la comisión histórica ocurrió "debajo" (outside = global).
    function _updateTick(int24 t, int128 delta, bool isUpper) internal {
        TickInfo storage info = ticks[t];
        uint128 before = info.liquidityGross;
        info.liquidityGross = _addDelta(before, delta);
        if (before == 0 && info.liquidityGross != 0) {
            if (t <= tick) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
            _insertTick(t);
        }
        // El borde inferior suma liquidez al cruzarlo hacia arriba; el superior la resta.
        info.liquidityNet = isUpper ? info.liquidityNet - delta : info.liquidityNet + delta;
    }

    /// @dev Comisiones por unidad de liquidez acumuladas DENTRO de [lower, upper).
    function _feeGrowthInside(int24 lower, int24 upper) internal view returns (uint256 in0, uint256 in1) {
        TickInfo storage lo = ticks[lower];
        TickInfo storage hi = ticks[upper];
        unchecked {
            uint256 below0 = tick >= lower ? lo.feeGrowthOutside0X128 : feeGrowthGlobal0X128 - lo.feeGrowthOutside0X128;
            uint256 below1 = tick >= lower ? lo.feeGrowthOutside1X128 : feeGrowthGlobal1X128 - lo.feeGrowthOutside1X128;
            uint256 above0 = tick < upper ? hi.feeGrowthOutside0X128 : feeGrowthGlobal0X128 - hi.feeGrowthOutside0X128;
            uint256 above1 = tick < upper ? hi.feeGrowthOutside1X128 : feeGrowthGlobal1X128 - hi.feeGrowthOutside1X128;
            in0 = feeGrowthGlobal0X128 - below0 - above0;
            in1 = feeGrowthGlobal1X128 - below1 - above1;
        }
    }

    /// @dev Inserta un tick manteniendo el arreglo ordenado.
    function _insertTick(int24 t) internal {
        initializedTicks.push(t);
        uint256 i = initializedTicks.length - 1;
        while (i > 0 && initializedTicks[i - 1] > t) {
            initializedTicks[i] = initializedTicks[i - 1];
            i--;
        }
        initializedTicks[i] = t;
    }

    /// @dev Elimina un tick del arreglo y borra su estado.
    function _removeTick(int24 t) internal {
        uint256 n = initializedTicks.length;
        for (uint256 i; i < n; i++) {
            if (initializedTicks[i] == t) {
                for (uint256 j = i; j + 1 < n; j++) {
                    initializedTicks[j] = initializedTicks[j + 1];
                }
                initializedTicks.pop();
                delete ticks[t];
                return;
            }
        }
    }

    /// @dev Próximo tick inicializado en la dirección del swap.
    ///      zeroForOne (precio baja): mayor tick inicializado <= tick actual.
    ///      oneForZero (precio sube): menor tick inicializado > tick actual.
    function _nextTick(bool zeroForOne) internal view returns (bool found, int24 next) {
        uint256 n = initializedTicks.length;
        if (zeroForOne) {
            for (uint256 i = n; i > 0; i--) {
                if (initializedTicks[i - 1] <= tick) return (true, initializedTicks[i - 1]);
            }
        } else {
            for (uint256 i; i < n; i++) {
                if (initializedTicks[i] > tick) return (true, initializedTicks[i]);
            }
        }
        return (false, 0);
    }

    // ------------------------------------------------------------------
    // Swap
    // ------------------------------------------------------------------

    /// @dev Estado mutable del bucle de swap (en memoria para evitar stack too deep).
    struct SwapState {
        uint256 remaining;
        uint256 amountOut;
        uint160 sqrtP;
        int24 tick;
        uint128 liquidity;
        uint256 feeGrowthGlobalX128;
    }

    /// @notice Swap exact-input.
    /// @param zeroForOne true: vende token0 por token1 (precio baja).
    /// @param amountIn Monto exacto a vender.
    /// @param amountOutMin Mínimo a recibir (protección de slippage).
    /// @param sqrtPriceLimitX96 Precio límite (0 = sin límite).
    function swap(bool zeroForOne, uint256 amountIn, uint256 amountOutMin, uint160 sqrtPriceLimitX96, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (sqrtPriceX96 == 0) revert NotInitialized();
        uint160 minS = TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK);
        uint160 maxS = TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK);
        if (sqrtPriceLimitX96 == 0) sqrtPriceLimitX96 = zeroForOne ? minS : maxS;
        if (zeroForOne ? (sqrtPriceLimitX96 >= sqrtPriceX96 || sqrtPriceLimitX96 < minS) : (sqrtPriceLimitX96 <= sqrtPriceX96 || sqrtPriceLimitX96 > maxS)) {
            revert InvalidPriceLimit();
        }

        SwapState memory s = SwapState({
            remaining: amountIn,
            amountOut: 0,
            sqrtP: sqrtPriceX96,
            tick: tick,
            liquidity: liquidity,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128
        });

        // Bucle: avanzamos tramo por tramo entre ticks inicializados.
        while (s.remaining > 0 && s.sqrtP != sqrtPriceLimitX96) {
            tick = s.tick; // _nextTick lee el storage
            (bool found, int24 nextT) = _nextTick(zeroForOne);
            uint160 sqrtNextTick = found ? TickMath.getSqrtPriceAtTick(nextT) : sqrtPriceLimitX96;
            // El objetivo del tramo no puede pasarse del límite del usuario.
            uint160 target = zeroForOne
                ? (sqrtNextTick < sqrtPriceLimitX96 ? sqrtPriceLimitX96 : sqrtNextTick)
                : (sqrtNextTick > sqrtPriceLimitX96 ? sqrtPriceLimitX96 : sqrtNextTick);

            uint160 sqrtNew = _swapStep(s, target, zeroForOne);

            if (found && sqrtNew == sqrtNextTick) {
                // Cruzamos un tick inicializado: invertimos sus acumuladores "outside"
                // y aplicamos su liquidityNet.
                TickInfo storage ti = ticks[nextT];
                unchecked {
                    ti.feeGrowthOutside0X128 = (zeroForOne ? s.feeGrowthGlobalX128 : feeGrowthGlobal0X128) - ti.feeGrowthOutside0X128;
                    ti.feeGrowthOutside1X128 = (zeroForOne ? feeGrowthGlobal1X128 : s.feeGrowthGlobalX128) - ti.feeGrowthOutside1X128;
                }
                int128 net = ti.liquidityNet;
                if (zeroForOne) net = -net;
                s.liquidity = _addDelta(s.liquidity, net);
                s.tick = zeroForOne ? nextT - 1 : nextT;
            } else if (sqrtNew != s.sqrtP) {
                s.tick = TickMath.getTickAtSqrtPrice(sqrtNew);
            }
            s.sqrtP = sqrtNew;
            if (!found && s.liquidity == 0) break; // sin más liquidez en esta dirección
        }

        // Persistimos el estado final.
        sqrtPriceX96 = s.sqrtP;
        tick = s.tick;
        liquidity = s.liquidity;
        if (zeroForOne) feeGrowthGlobal0X128 = s.feeGrowthGlobalX128;
        else feeGrowthGlobal1X128 = s.feeGrowthGlobalX128;

        amountOut = s.amountOut;
        if (amountOut < amountOutMin) revert InsufficientOutput();
        uint256 paid = amountIn - s.remaining; // si se alcanzó el límite, cobra solo lo usado
        if (zeroForOne) {
            token0.safeTransferFrom(msg.sender, address(this), paid);
            token1.safeTransfer(recipient, amountOut);
        } else {
            token1.safeTransferFrom(msg.sender, address(this), paid);
            token0.safeTransfer(recipient, amountOut);
        }
        emit Swap(msg.sender, recipient, zeroForOne, paid, amountOut, s.sqrtP, s.tick);
    }

    /// @dev Un tramo del swap con liquidez constante. Devuelve el nuevo sqrtP y actualiza `s`.
    function _swapStep(SwapState memory s, uint160 target, bool zeroForOne) internal view returns (uint160 sqrtNew) {
        if (s.liquidity == 0) return target; // tramo vacío: saltamos sin intercambiar
        uint256 lessFee = Math.mulDiv(s.remaining, FEE_DEN - fee, FEE_DEN);
        uint256 toTarget = zeroForOne
            ? LiquidityMath.amount0Delta(target, s.sqrtP, s.liquidity, true)
            : LiquidityMath.amount1Delta(s.sqrtP, target, s.liquidity, true);
        uint256 inUsed;
        uint256 feeAmt;
        if (lessFee >= toTarget) {
            // Llegamos al objetivo y sobra entrada para el próximo tramo.
            sqrtNew = target;
            inUsed = toTarget;
            feeAmt = Math.mulDiv(inUsed, fee, FEE_DEN - fee, Math.Rounding.Ceil);
        } else {
            // Nos quedamos a mitad de tramo: consumimos todo lo que queda.
            sqrtNew = zeroForOne
                ? LiquidityMath.nextSqrtPriceFromAmount0(s.sqrtP, s.liquidity, lessFee)
                : LiquidityMath.nextSqrtPriceFromAmount1(s.sqrtP, s.liquidity, lessFee);
            inUsed = zeroForOne
                ? LiquidityMath.amount0Delta(sqrtNew, s.sqrtP, s.liquidity, true)
                : LiquidityMath.amount1Delta(s.sqrtP, sqrtNew, s.liquidity, true);
            if (inUsed > s.remaining) inUsed = s.remaining;
            feeAmt = s.remaining - inUsed; // el resto (redondeo incluido) va a comisión
        }
        uint256 out = zeroForOne
            ? LiquidityMath.amount1Delta(sqrtNew, s.sqrtP, s.liquidity, false)
            : LiquidityMath.amount0Delta(s.sqrtP, sqrtNew, s.liquidity, false);
        if (inUsed + feeAmt > s.remaining) feeAmt = s.remaining - inUsed;
        s.remaining -= inUsed + feeAmt;
        s.amountOut += out;
        unchecked {
            s.feeGrowthGlobalX128 += Math.mulDiv(feeAmt, Q128, s.liquidity);
        }
    }
}
