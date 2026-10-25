// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TickMath — conversión entre ticks y raíz cuadrada del precio (Q64.96)
/// @notice En liquidez concentrada el precio se discretiza en "ticks": precio(t) = 1.0001^t.
///         Guardamos sqrt(precio) en punto fijo Q64.96 (valor * 2^96) porque las fórmulas de
///         montos son lineales en sqrt(P), lo que simplifica y abarata la matemática.
/// @dev Implementación propia (clean-room) por exponenciación binaria:
///      sqrt(1.0001)^|t| = Π sqrt(1.0001)^(2^i) para cada bit i encendido de |t|.
///      Es menos precisa y más cara que la tabla de constantes de Uniswap V3, pero es
///      monotónica y suficiente para fines educativos. El rango se limita a ±400.000 ticks.
library TickMath {
    /// @notice Tick mínimo y máximo soportados.
    int24 internal constant MIN_TICK = -400_000;
    int24 internal constant MAX_TICK = 400_000;

    /// @notice 2^96, la unidad en Q64.96.
    uint256 internal constant Q96 = 2 ** 96;

    /// @notice floor(sqrt(1.0001) * 2^96), calculado off-chain con 80 dígitos de precisión.
    uint256 internal constant SQRT_BASE_Q96 = 79232123823359799118286999567;

    error TickOutOfRange();
    error PriceOutOfRange();

    /// @notice sqrt(1.0001^tick) * 2^96.
    /// @dev Para ticks negativos calculamos el positivo e invertimos: Q96^2 / r.
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        if (tick < MIN_TICK || tick > MAX_TICK) revert TickOutOfRange();
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        uint256 r = Q96;
        uint256 base = SQRT_BASE_Q96;
        // Exponenciación por cuadrados en punto fijo.
        while (absTick != 0) {
            if (absTick & 1 == 1) r = Math.mulDiv(r, base, Q96);
            absTick >>= 1;
            if (absTick != 0) base = Math.mulDiv(base, base, Q96);
        }
        if (tick < 0) r = Math.mulDiv(Q96, Q96, r);
        return uint160(r);
    }

    /// @notice Mayor tick t tal que getSqrtPriceAtTick(t) <= sqrtPriceX96 (búsqueda binaria).
    /// @dev ~20 iteraciones; cada una evalúa getSqrtPriceAtTick. Costoso pero simple y correcto.
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24) {
        if (sqrtPriceX96 < getSqrtPriceAtTick(MIN_TICK) || sqrtPriceX96 > getSqrtPriceAtTick(MAX_TICK)) {
            revert PriceOutOfRange();
        }
        int256 lo = MIN_TICK;
        int256 hi = MAX_TICK;
        while (lo < hi) {
            // redondeo hacia arriba para que el bucle termine con lo == mayor válido
            int256 mid = (lo + hi + 1) >> 1; // shift aritmético => floor también con negativos
            if (getSqrtPriceAtTick(int24(mid)) <= sqrtPriceX96) lo = mid;
            else hi = mid - 1;
        }
        return int24(lo);
    }
}
