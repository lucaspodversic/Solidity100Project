// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILMath} from "./libraries/ILMath.sol";

/// @title ILCalculator — calculadora on-chain de pérdida impermanente + registro de posiciones
/// @notice Expone ILMath como funciones `view`/`pure` (consultables desde front-ends o scripts)
///         y permite registrar el punto de entrada de una posición para luego consultar su
///         IL contra un precio actual informado por un oráculo de confianza.
contract ILCalculator {
    using ILMath for uint256;

    /// @notice Punto de entrada de una posición registrada.
    struct Entry {
        uint256 x0; // cantidad de X al entrar (WAD)
        uint256 y0; // cantidad de Y al entrar (WAD)
        uint256 p0; // precio de entrada (Y por X, WAD)
        uint256 pa; // límite inferior (0 = rango completo x·y=k)
        uint256 pb; // límite superior
        uint64 openedAt;
    }

    /// @notice Posiciones registradas por usuario.
    mapping(address => Entry[]) public entries;

    event EntryRecorded(address indexed user, uint256 indexed id, uint256 p0, uint256 pa, uint256 pb);

    /// @notice IL de x·y=k para un cambio de precio r = p1/p0.
    function ilFullRange(uint256 p0, uint256 p1) public pure returns (uint256) {
        return ILMath.ilConstantProduct((p1 * 1e18) / p0);
    }

    /// @notice IL de una posición concentrada.
    function ilRange(uint256 p0, uint256 p1, uint256 pa, uint256 pb)
        public
        pure
        returns (uint256 il, uint256 lpVal, uint256 hodlVal)
    {
        return ILMath.ilConcentrated(p0, p1, pa, pb);
    }

    /// @notice Escenarios: IL para una lista de precios futuros (útil para tablas o gráficos).
    function scenarios(uint256 p0, uint256[] calldata prices, uint256 pa, uint256 pb)
        external
        pure
        returns (uint256[] memory ils)
    {
        ils = new uint256[](prices.length);
        for (uint256 i; i < prices.length; i++) {
            if (pa == 0) ils[i] = ilFullRange(p0, prices[i]);
            else (ils[i],,) = ILMath.ilConcentrated(p0, prices[i], pa, pb);
        }
    }

    /// @notice Registra una posición (sólo informativo; no custodia fondos).
    function record(uint256 x0, uint256 y0, uint256 p0, uint256 pa, uint256 pb) external returns (uint256 id) {
        require(p0 > 0, "precio");
        require(pa == 0 ? pb == 0 : pa < pb, "rango");
        entries[msg.sender].push(Entry(x0, y0, p0, pa, pb, uint64(block.timestamp)));
        id = entries[msg.sender].length - 1;
        emit EntryRecorded(msg.sender, id, p0, pa, pb);
    }

    /// @notice Reporte de una posición registrada al precio `p1`.
    /// @return il Pérdida impermanente (WAD).
    /// @return lpValue Valor estimado de la posición (en Y).
    /// @return hodl Valor de mantener los tokens (en Y).
    /// @return aprToBreakeven APR de comisiones necesario para empatar (WAD).
    function report(address user, uint256 id, uint256 p1)
        external
        view
        returns (uint256 il, uint256 lpValue, uint256 hodl, uint256 aprToBreakeven)
    {
        Entry memory e = entries[user][id];
        if (e.pa == 0) {
            lpValue = ILMath.lpValueCP(e.x0, e.y0, p1);
            hodl = ILMath.hodlValue(e.x0, e.y0, p1);
            il = hodl > lpValue ? ((hodl - lpValue) * 1e18) / hodl : 0;
        } else {
            uint256 lpUnit;
            uint256 hodlUnit;
            (il, lpUnit, hodlUnit) = ILMath.ilConcentrated(e.p0, p1, e.pa, e.pb);
            // Escalamos por el valor real de la posición al entrar
            uint256 v0 = (e.x0 * e.p0) / 1e18 + e.y0;
            (uint256 xu, uint256 yu) = ILMath.amountsPerLiquidity(e.p0, e.pa, e.pb);
            uint256 v0Unit = (xu * e.p0) / 1e18 + yu;
            lpValue = (lpUnit * v0) / v0Unit;
            hodl = (hodlUnit * v0) / v0Unit;
        }
        uint256 d = (block.timestamp - e.openedAt) / 1 days;
        aprToBreakeven = ILMath.breakevenApr(lpValue, hodl, d == 0 ? 1 : d);
    }
}
