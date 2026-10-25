// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LiquidityMath — fórmulas de montos para liquidez concentrada
/// @notice Con liquidez L constante entre dos precios sqrt(Pa) < sqrt(Pb):
///           Δtoken0 = L · (sqrtPb − sqrtPa) / (sqrtPa · sqrtPb)
///           Δtoken1 = L · (sqrtPb − sqrtPa)
///         Todas las cantidades sqrt están en Q64.96.
/// @dev El redondeo SIEMPRE favorece al pool: lo que el pool recibe se redondea hacia arriba
///      y lo que entrega hacia abajo. Si no, un atacante podría extraer polvo en bucle.
library LiquidityMath {
    uint256 internal constant Q96 = 2 ** 96;

    /// @notice Cantidad de token0 entre dos precios para liquidez L.
    function amount0Delta(uint160 sA, uint160 sB, uint128 liquidity, bool roundUp) internal pure returns (uint256) {
        if (sA > sB) (sA, sB) = (sB, sA);
        uint256 num1 = uint256(liquidity) << 96;
        uint256 num2 = sB - sA;
        if (roundUp) {
            return Math.ceilDiv(Math.mulDiv(num1, num2, sB, Math.Rounding.Ceil), sA);
        }
        return Math.mulDiv(num1, num2, sB) / sA;
    }

    /// @notice Cantidad de token1 entre dos precios para liquidez L.
    function amount1Delta(uint160 sA, uint160 sB, uint128 liquidity, bool roundUp) internal pure returns (uint256) {
        if (sA > sB) (sA, sB) = (sB, sA);
        return Math.mulDiv(liquidity, sB - sA, Q96, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    /// @notice Nuevo sqrtP al AGREGAR `amount` de token0 (el precio baja).
    /// @dev sqrtP' = L·sqrtP / (L + amount·sqrtP / Q96), redondeado hacia arriba
    ///      (precio más alto => el trader recibe un poco menos de token1).
    function nextSqrtPriceFromAmount0(uint160 sP, uint128 liquidity, uint256 amount) internal pure returns (uint160) {
        if (amount == 0) return sP;
        uint256 num = uint256(liquidity) << 96;
        uint256 denom = num + amount * sP;
        return uint160(Math.mulDiv(num, sP, denom, Math.Rounding.Ceil));
    }

    /// @notice Nuevo sqrtP al AGREGAR `amount` de token1 (el precio sube).
    /// @dev sqrtP' = sqrtP + amount·Q96 / L, redondeado hacia abajo.
    function nextSqrtPriceFromAmount1(uint160 sP, uint128 liquidity, uint256 amount) internal pure returns (uint160) {
        return uint160(uint256(sP) + Math.mulDiv(amount, Q96, liquidity));
    }
}
