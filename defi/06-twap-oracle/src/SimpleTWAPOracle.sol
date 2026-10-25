// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CPAMMPair} from "./amm/CPAMMPair.sol";
import {OracleLibrary} from "./libraries/OracleLibrary.sol";

/// @title SimpleTWAPOracle — TWAP de ventana fija para un único par
/// @notice Cada `PERIOD` segundos alguien (keeper) llama a `update()`, que guarda el precio
///         promedio del período terminado. `consult` usa ese promedio. Es barato y simple,
///         pero el precio puede tener hasta 2·PERIOD de antigüedad.
contract SimpleTWAPOracle {
    /// @notice Longitud de la ventana.
    uint32 public immutable PERIOD;
    /// @notice Antigüedad máxima aceptada al consultar (protección contra keeper caído).
    uint32 public immutable MAX_AGE;

    address public immutable pair;
    address public immutable token0;
    address public immutable token1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;
    /// @notice Precios promedio del último período (UQ112x112).
    uint256 public price0Average;
    uint256 public price1Average;

    error PeriodNotElapsed();
    error NoReserves();
    error InvalidToken();
    error StalePrice();
    error NotInitialized();

    constructor(address _pair, uint32 _period, uint32 _maxAge) {
        require(_maxAge >= _period, "maxAge < period");
        pair = _pair;
        PERIOD = _period;
        MAX_AGE = _maxAge;
        token0 = CPAMMPair(_pair).token0();
        token1 = CPAMMPair(_pair).token1();
        (uint112 r0, uint112 r1,) = CPAMMPair(_pair).getReserves();
        if (r0 == 0 || r1 == 0) revert NoReserves();
        (price0CumulativeLast, price1CumulativeLast, blockTimestampLast) =
            OracleLibrary.currentCumulativePrices(_pair);
    }

    /// @notice Cierra el período actual y calcula el promedio. Cualquiera puede llamarla.
    function update() external {
        (uint256 c0, uint256 c1, uint32 ts) = OracleLibrary.currentCumulativePrices(pair);
        uint32 elapsed;
        unchecked {
            elapsed = ts - blockTimestampLast;
        }
        if (elapsed < PERIOD) revert PeriodNotElapsed();
        unchecked {
            price0Average = (c0 - price0CumulativeLast) / elapsed;
            price1Average = (c1 - price1CumulativeLast) / elapsed;
        }
        price0CumulativeLast = c0;
        price1CumulativeLast = c1;
        blockTimestampLast = ts;
    }

    /// @notice Cuánto `token` contrario valen `amountIn` de `token` según el último TWAP.
    function consult(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        if (price0Average == 0 && price1Average == 0) revert NotInitialized();
        unchecked {
            if (OracleLibrary.currentBlockTimestamp() - blockTimestampLast > MAX_AGE) revert StalePrice();
        }
        if (token == token0) return (price0Average * amountIn) >> 112;
        if (token == token1) return (price1Average * amountIn) >> 112;
        revert InvalidToken();
    }
}
