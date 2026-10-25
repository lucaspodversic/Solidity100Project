// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interfaz común para comparar las tres arquitecturas desde un consumidor.
interface IOracle {
    /// @return value último valor aceptado
    /// @return updatedAt timestamp de ese valor
    function latest() external view returns (uint256 value, uint256 updatedAt);
}

/// @notice Utilidad: mediana de un arreglo en memoria (insertion sort; n pequeño y acotado).
library Median {
    function compute(uint256[] memory a) internal pure returns (uint256) {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; i++) {
            uint256 k = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > k) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = k;
        }
        // n par: promedio de los dos centrales
        return n % 2 == 1 ? a[n / 2] : (a[n / 2 - 1] + a[n / 2]) / 2;
    }
}
