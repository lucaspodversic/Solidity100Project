// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ILMath — matemática de pérdida impermanente (IL) en punto fijo WAD (1e18)
/// @notice Convenciones:
///         - Los precios están expresados en "token Y por 1 token X", en WAD.
///         - Los valores se miden en unidades de Y, en WAD.
///         - Un IL de 0,2e18 significa que la posición LP vale 20 % menos que haber
///           mantenido (HODL) los mismos tokens iniciales.
library ILMath {
    uint256 internal constant WAD = 1e18;

    error ZeroPrice();
    error BadRange();

    /// @notice √p en WAD: √(p·1e18).
    function sqrtWad(uint256 p) internal pure returns (uint256) {
        return Math.sqrt(p * WAD);
    }

    /// @notice IL de un pool x·y=k cuando el precio cambia en un factor `r` = P1/P0.
    /// @dev Fórmula cerrada: IL = 1 − 2√r / (1 + r). Siempre ≥ 0 y simétrica en r y 1/r.
    ///      Ejemplos: r=2 → 5,72 %; r=4 → 20 %; r=0,25 → 20 %.
    function ilConstantProduct(uint256 rWad) internal pure returns (uint256) {
        if (rWad == 0) revert ZeroPrice();
        uint256 num = 2 * sqrtWad(rWad); // 2√r en WAD
        uint256 den = WAD + rWad; // 1 + r
        uint256 ratio = Math.mulDiv(num, WAD, den); // ≤ 1e18 por AM-GM
        return ratio >= WAD ? 0 : WAD - ratio;
    }

    /// @notice Valor de una posición x·y=k luego de que el precio pasa a `p1`.
    /// @dev Con k = x0·y0, en equilibrio x = √(k/p) e y = √(k·p), así que valor = 2√(k·p1).
    /// @param x0 Cantidad inicial de X (WAD).
    /// @param y0 Cantidad inicial de Y (WAD).
    function lpValueCP(uint256 x0, uint256 y0, uint256 p1) internal pure returns (uint256) {
        // k·p1 en WAD³ → raíz en WAD^(3/2); lo hacemos en dos pasos para no desbordar:
        // √(x0·y0) es la "liquidez" L (WAD) y valor = 2·L·√p1.
        uint256 l = Math.sqrt(x0 * y0); // WAD
        return 2 * Math.mulDiv(l, sqrtWad(p1), WAD);
    }

    /// @notice Valor de haber mantenido (HODL) x0 e y0 con el precio p1.
    function hodlValue(uint256 x0, uint256 y0, uint256 p1) internal pure returns (uint256) {
        return Math.mulDiv(x0, p1, WAD) + y0;
    }

    /// @notice Tokens por unidad de liquidez (L = 1 WAD) de un rango [pa, pb] al precio p.
    /// @dev Fórmulas de Uniswap V3:
    ///      p ≤ pa: todo en X: x = 1/√pa − 1/√pb, y = 0
    ///      p ≥ pb: todo en Y: x = 0, y = √pb − √pa
    ///      dentro: x = 1/√p − 1/√pb, y = √p − √pa
    function amountsPerLiquidity(uint256 p, uint256 pa, uint256 pb) internal pure returns (uint256 x, uint256 y) {
        if (pa == 0 || pa >= pb) revert BadRange();
        if (p == 0) revert ZeroPrice();
        uint256 sa = sqrtWad(pa);
        uint256 sb = sqrtWad(pb);
        uint256 sp = sqrtWad(p);
        if (sp <= sa) {
            x = Math.mulDiv(WAD, WAD, sa) - Math.mulDiv(WAD, WAD, sb);
        } else if (sp >= sb) {
            y = sb - sa;
        } else {
            x = Math.mulDiv(WAD, WAD, sp) - Math.mulDiv(WAD, WAD, sb);
            y = sp - sa;
        }
    }

    /// @notice IL de una posición concentrada en [pa, pb] abierta a p0, evaluada a p1.
    /// @return il Pérdida relativa vs. HODL (WAD).
    /// @return lpVal Valor de la posición LP por unidad de liquidez.
    /// @return hodlVal Valor de HODL por unidad de liquidez.
    function ilConcentrated(uint256 p0, uint256 p1, uint256 pa, uint256 pb)
        internal
        pure
        returns (uint256 il, uint256 lpVal, uint256 hodlVal)
    {
        (uint256 x0, uint256 y0) = amountsPerLiquidity(p0, pa, pb);
        (uint256 x1, uint256 y1) = amountsPerLiquidity(p1, pa, pb);
        lpVal = Math.mulDiv(x1, p1, WAD) + y1;
        hodlVal = Math.mulDiv(x0, p1, WAD) + y0;
        il = lpVal >= hodlVal ? 0 : Math.mulDiv(hodlVal - lpVal, WAD, hodlVal);
    }

    /// @notice Comisiones (en Y) que habría que cobrar para empatar con HODL.
    function breakevenFees(uint256 lpVal, uint256 hodlVal) internal pure returns (uint256) {
        return hodlVal > lpVal ? hodlVal - lpVal : 0;
    }

    /// @notice APR de comisiones (WAD) necesario para empatar en `daysHeld` días.
    function breakevenApr(uint256 lpVal, uint256 hodlVal, uint256 daysHeld) internal pure returns (uint256) {
        require(daysHeld > 0, "dias");
        uint256 fees = breakevenFees(lpVal, hodlVal);
        // (fees / valorInicialAprox) * 365 / días; usamos hodlVal como base.
        return Math.mulDiv(fees * 365, WAD, hodlVal * daysHeld);
    }
}
