// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PositionSimulator — simulador determinístico de posiciones DeFi (todo `pure`)
/// @notice Responde preguntas del tipo "¿qué le pasa a mi posición apalancada si ETH cae
///         10 % por día durante una semana?" sin tocar ningún protocolo real:
///           * `simulate`: evolución paso a paso de una posición de lending (colateral volátil,
///             deuda estable) con intereses, precio y liquidaciones parciales.
///           * `leverageLoop`: resultado de "depositar → pedir → re-depositar" N veces.
///           * `liquidationPrice`: precio al que HF = 1.
///           * `lpValueRatio`: valor de una posición LP x·y=k vs. HODL (impermanent loss).
/// @dev Unidades: WAD (1e18) para todo. Precio = USD por unidad de colateral.
///      Al ser `pure`, se puede llamar gratis vía eth_call desde un frontend o un script.
contract PositionSimulator {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    /// @notice Parámetros de la posición y del protocolo simulado.
    struct Params {
        uint256 collateral; // unidades de colateral (WAD)
        uint256 debt; // deuda en USD (WAD)
        uint256 price; // precio inicial del colateral (WAD)
        uint256 liqThreshold; // p. ej. 0.825e18
        uint256 liqBonus; // p. ej. 0.05e18 (5 % de premio al liquidador)
        uint256 closeFactor; // fracción de la deuda liquidable por evento, p. ej. 0.5e18
        uint256 borrowApr; // tasa anual de la deuda (WAD)
        uint256 supplyApr; // tasa anual que gana el colateral (WAD)
        uint256 stepSeconds; // duración de cada paso
    }

    /// @notice Foto del estado al final de cada paso.
    struct Snapshot {
        uint256 price;
        uint256 collateral;
        uint256 debt;
        uint256 healthFactor; // max = sin deuda
        int256 equity; // colateral·precio − deuda (puede ser negativo = deuda incobrable)
        bool liquidated; // hubo liquidación en este paso
        uint256 seized; // colateral confiscado en este paso
    }

    error BadParams();

    /// @notice Health factor = colateral·precio·umbral / deuda.
    function healthFactor(uint256 collateral, uint256 price, uint256 debt, uint256 lt) public pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return Math.mulDiv(Math.mulDiv(collateral, price, WAD), lt, debt);
    }

    /// @notice Precio del colateral al que la posición se vuelve liquidable (HF = 1).
    function liquidationPrice(uint256 collateral, uint256 debt, uint256 lt) public pure returns (uint256) {
        if (collateral == 0) return type(uint256).max;
        return Math.mulDiv(debt, WAD * WAD, collateral * lt, Math.Rounding.Ceil);
    }

    /// @notice Simula la posición a lo largo de `moves` (variación de precio por paso, en bps
    ///         con signo: −1000 = −10 %).
    /// @dev Orden en cada paso: 1) intereses del intervalo, 2) movimiento de precio,
    ///      3) chequeo de HF y, si < 1, UNA liquidación parcial (como haría un bot por bloque).
    function simulate(Params memory p, int256[] memory moves) public pure returns (Snapshot[] memory out) {
        if (p.price == 0 || p.liqThreshold >= WAD || p.closeFactor > WAD) revert BadParams();
        out = new Snapshot[](moves.length);
        uint256 col = p.collateral;
        uint256 debt = p.debt;
        uint256 price = p.price;
        for (uint256 i; i < moves.length; i++) {
            // 1) intereses simples del intervalo (compuestos entre intervalos)
            debt += Math.mulDiv(debt, p.borrowApr * p.stepSeconds, WAD * YEAR);
            col += Math.mulDiv(col, p.supplyApr * p.stepSeconds, WAD * YEAR);
            // 2) precio (con piso en 1 wei para no dividir por cero)
            int256 np = int256(price) + (int256(price) * moves[i]) / 10_000;
            price = np <= 0 ? 1 : uint256(np);
            // 3) liquidación
            Snapshot memory s;
            uint256 hf = healthFactor(col, price, debt, p.liqThreshold);
            if (hf < WAD && debt > 0) {
                uint256 repay = Math.mulDiv(debt, p.closeFactor, WAD);
                uint256 seize = Math.mulDiv(repay, WAD + p.liqBonus, price); // en unidades
                if (seize > col) {
                    // colateral insuficiente: se confisca todo y se repaga lo que cubre
                    seize = col;
                    repay = Math.mulDiv(col, price, WAD + p.liqBonus);
                }
                col -= seize;
                debt -= repay;
                s.liquidated = true;
                s.seized = seize;
                hf = healthFactor(col, price, debt, p.liqThreshold);
            }
            s.price = price;
            s.collateral = col;
            s.debt = debt;
            s.healthFactor = hf;
            s.equity = int256(Math.mulDiv(col, price, WAD)) - int256(debt);
            out[i] = s;
        }
    }

    /// @notice Apalancamiento por loop: depositar `equity`, pedir `ltv`, re-depositar, N veces.
    /// @return collateral Colateral total (en las mismas unidades que equity).
    /// @return debt Deuda total.
    /// @return leverage collateral/equity (WAD). Tiende a 1/(1−ltv) cuando loops → ∞.
    function leverageLoop(uint256 equity, uint256 ltv, uint256 loops)
        public
        pure
        returns (uint256 collateral, uint256 debt, uint256 leverage)
    {
        if (ltv >= WAD || equity == 0) revert BadParams();
        uint256 chunk = equity;
        for (uint256 i; i <= loops; i++) {
            collateral += chunk;
            if (i == loops) break;
            chunk = Math.mulDiv(chunk, ltv, WAD); // lo que se pide prestado y se re-deposita
            debt += chunk;
        }
        leverage = Math.mulDiv(collateral, WAD, equity);
    }

    /// @notice APR neto sobre el capital propio de una posición apalancada.
    /// @dev netApr = (col·supplyApr − debt·borrowApr) / equity. Negativo si el carry es malo.
    function netApr(uint256 collateral, uint256 debt, uint256 supplyApr, uint256 borrowApr)
        public
        pure
        returns (int256)
    {
        int256 eq = int256(collateral) - int256(debt);
        if (eq <= 0) revert BadParams();
        int256 earn = int256(Math.mulDiv(collateral, supplyApr, WAD)) - int256(Math.mulDiv(debt, borrowApr, WAD));
        return (earn * 1e18) / eq;
    }

    /// @notice Valor de una posición LP x·y=k relativo a HODL cuando el precio se multiplica
    ///         por `r`: 2√r / (1 + r). IL = 1 − este valor.
    /// @param r Ratio de precio final/inicial (WAD). 2e18 = el precio se duplicó.
    function lpValueRatio(uint256 r) public pure returns (uint256) {
        return Math.mulDiv(2 * Math.sqrt(r * WAD), WAD, WAD + r);
    }
}
