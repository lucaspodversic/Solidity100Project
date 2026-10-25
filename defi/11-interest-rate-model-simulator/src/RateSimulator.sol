// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IInterestRateModel} from "./IInterestRateModel.sol";

/// @title RateSimulator — simulador on-chain de modelos de tasa de interés
/// @notice Permite:
///         - `curve`: muestrear la curva r(U) de un modelo en una grilla de utilizaciones;
///         - `simulate`: recorrer un escenario de utilizaciones en el tiempo y calcular el
///           índice de deuda, el interés pagado por un préstamo y el ganado por depositantes;
///         - `compare`: comparar varios modelos bajo el mismo escenario.
///         Pensado para usar desde scripts de Foundry o `eth_call` (sin estado propio).
contract RateSimulator {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    struct Step {
        uint256 utilization; // WAD
        uint256 duration; // segundos
    }

    struct Result {
        uint256 finalBorrowIndex; // WAD, arranca en 1e18
        uint256 finalSupplyIndex; // WAD
        uint256 avgBorrowApr; // promedio ponderado por tiempo
        uint256 maxBorrowApr;
        uint256 debtInterest; // interés sobre `principal`
        uint256 supplyInterest; // interés de un depósito de `principal`
    }

    error EmptyScenario();

    /// @notice Muestrea r(U) en los puntos dados.
    function curve(IInterestRateModel model, uint256[] calldata utils) external view returns (uint256[] memory rates) {
        rates = new uint256[](utils.length);
        for (uint256 i; i < utils.length; i++) {
            rates[i] = model.borrowRate(utils[i]);
        }
    }

    /// @notice Tasa de depósito: r_borrow · U · (1 − reserveFactor).
    function supplyRate(uint256 borrowApr, uint256 u, uint256 reserveFactor) public pure returns (uint256) {
        return (((borrowApr * u) / WAD) * (WAD - reserveFactor)) / WAD;
    }

    /// @notice Ejecuta un escenario. Para modelos con estado, llama a `update` en cada paso
    ///         (por eso no es `view`; usar desde script o como eth_call).
    /// @dev Interés compuesto por paso: index *= 1 + r·dt/año (con pasos chicos ≈ continuo).
    function simulate(IInterestRateModel model, Step[] calldata steps, uint256 principal, uint256 reserveFactor)
        public
        returns (Result memory res)
    {
        if (steps.length == 0) revert EmptyScenario();
        res.finalBorrowIndex = WAD;
        res.finalSupplyIndex = WAD;
        uint256 weighted;
        uint256 totalTime;
        for (uint256 i; i < steps.length; i++) {
            Step calldata s = steps[i];
            uint256 r = model.borrowRate(s.utilization);
            if (r > res.maxBorrowApr) res.maxBorrowApr = r;
            uint256 sr = supplyRate(r, s.utilization, reserveFactor);
            res.finalBorrowIndex += (res.finalBorrowIndex * r * s.duration) / (WAD * YEAR);
            res.finalSupplyIndex += (res.finalSupplyIndex * sr * s.duration) / (WAD * YEAR);
            weighted += r * s.duration;
            totalTime += s.duration;
            model.update(s.utilization, s.duration);
        }
        res.avgBorrowApr = totalTime == 0 ? 0 : weighted / totalTime;
        res.debtInterest = (principal * (res.finalBorrowIndex - WAD)) / WAD;
        res.supplyInterest = (principal * (res.finalSupplyIndex - WAD)) / WAD;
    }

    /// @notice Corre el mismo escenario para varios modelos.
    function compare(IInterestRateModel[] calldata models, Step[] calldata steps, uint256 principal, uint256 rf)
        external
        returns (Result[] memory results)
    {
        results = new Result[](models.length);
        for (uint256 i; i < models.length; i++) {
            results[i] = simulate(models[i], steps, principal, rf);
        }
    }

    /// @notice Utilidad: escenario de "corrida bancaria" — U sube linealmente de `from` a `to`.
    function rampScenario(uint256 from, uint256 to, uint256 n, uint256 stepDuration)
        external
        pure
        returns (Step[] memory steps)
    {
        steps = new Step[](n);
        for (uint256 i; i < n; i++) {
            uint256 u = n == 1 ? to : from + ((to > from ? to - from : 0) * i) / (n - 1);
            steps[i] = Step(u, stepDuration);
        }
    }
}
