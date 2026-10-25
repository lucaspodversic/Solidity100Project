// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CPAMMPair} from "../amm/CPAMMPair.sol";

/// @title OracleLibrary — utilidades para leer TWAP de pares CPAMM
/// @notice El par sólo actualiza sus acumuladores cuando alguien interactúa con él. Si nadie
///         operó en este bloque, calculamos el acumulador "contrafactual" que tendría si se
///         hubiera llamado a `sync()` ahora, sin gastar gas en una escritura.
library OracleLibrary {
    /// @notice Timestamp en 32 bits, igual que en el par (overflow modular cada ~136 años).
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    /// @notice Acumuladores de precio actualizados al bloque actual.
    /// @return price0Cumulative Σ(precio de token0 en token1, UQ112x112) · segundos.
    /// @return price1Cumulative Σ(precio de token1 en token0, UQ112x112) · segundos.
    /// @return blockTimestamp Timestamp de 32 bits usado.
    function currentCumulativePrices(address pair)
        internal
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = CPAMMPair(pair).price0CumulativeLast();
        price1Cumulative = CPAMMPair(pair).price1CumulativeLast();
        (uint112 r0, uint112 r1, uint32 last) = CPAMMPair(pair).getReserves();
        if (last != blockTimestamp && r0 != 0 && r1 != 0) {
            unchecked {
                // Igual que en el par: overflow deseado (sólo importan las diferencias).
                uint32 elapsed = blockTimestamp - last;
                price0Cumulative += ((uint256(r1) << 112) / r0) * elapsed;
                price1Cumulative += ((uint256(r0) << 112) / r1) * elapsed;
            }
        }
    }

    /// @notice Convierte un precio promedio (diferencia de acumuladores / tiempo) en un monto.
    /// @dev La resta se hace `unchecked` porque los acumuladores pueden haber dado la vuelta:
    ///      en aritmética modular la diferencia sigue siendo correcta.
    function computeAmountOut(uint256 cumStart, uint256 cumEnd, uint32 timeElapsed, uint256 amountIn)
        internal
        pure
        returns (uint256)
    {
        uint256 priceAverage;
        unchecked {
            priceAverage = (cumEnd - cumStart) / timeElapsed; // UQ112x112
        }
        return (priceAverage * amountIn) >> 112;
    }
}
