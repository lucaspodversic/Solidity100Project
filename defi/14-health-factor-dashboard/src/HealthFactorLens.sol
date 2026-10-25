// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LendingPool} from "./protocol/LendingPool.sol";
import {PriceOracle} from "./protocol/PriceOracle.sol";

/// @title HealthFactorLens — "dashboard" on-chain de salud de posiciones
/// @notice Contrato sólo-lectura (lens) que agrega todo lo que un frontend de riesgo necesita
///         en UNA llamada `eth_call`:
///         - desglose por activo (depositado, adeudado, valores USD, parámetros de riesgo);
///         - totales, health factor, capacidad de préstamo restante y categoría de riesgo;
///         - precio de liquidación de un colateral (manteniendo el resto constante);
///         - stress test: HF ante caídas porcentuales de un activo;
///         - máximos retirable / prestable sin quedar insolvente;
///         - escaneo por lotes para monitorear muchas cuentas.
/// @dev No tiene estado ni permisos: es seguro de desplegar y usar por cualquiera. Lee los
///      índices del último `accrue` (puede subestimar intereses unos segundos/minutos).
contract HealthFactorLens {
    uint256 internal constant WAD = 1e18;

    LendingPool public immutable pool;

    enum Risk {
        NoDebt, // sin deuda
        Safe, // HF ≥ 1,5
        Warning, // 1,1 ≤ HF < 1,5
        Danger, // 1 ≤ HF < 1,1
        Liquidatable // HF < 1
    }

    struct AssetLine {
        address asset;
        uint256 price; // USD WAD por unidad entera
        uint256 supplied; // unidades del token
        uint256 borrowed;
        uint256 suppliedUsd;
        uint256 borrowedUsd;
        uint256 ltv;
        uint256 liquidationThreshold;
    }

    struct Dashboard {
        AssetLine[] lines;
        uint256 collateralUsd;
        uint256 debtUsd;
        uint256 borrowLimitUsd;
        uint256 liquidationUsd;
        uint256 availableToBorrowUsd;
        uint256 healthFactor;
        uint256 ltvUsed; // deuda / colateral (WAD)
        Risk risk;
    }

    struct Params {
        uint8 decimals;
        uint256 ltv;
        uint256 lt;
    }

    constructor(LendingPool _pool) {
        pool = _pool;
    }

    // ------------------------------------------------------------------
    // Dashboard completo
    // ------------------------------------------------------------------

    function dashboard(address user) external view returns (Dashboard memory d) {
        uint256 n = pool.assetsCount();
        d.lines = new AssetLine[](n);
        for (uint256 i; i < n; i++) {
            AssetLine memory l = _line(user, pool.assetList(i));
            d.lines[i] = l;
            d.collateralUsd += l.suppliedUsd;
            d.debtUsd += l.borrowedUsd;
            d.borrowLimitUsd += Math.mulDiv(l.suppliedUsd, l.ltv, WAD);
            d.liquidationUsd += Math.mulDiv(l.suppliedUsd, l.liquidationThreshold, WAD);
        }
        d.availableToBorrowUsd = d.borrowLimitUsd > d.debtUsd ? d.borrowLimitUsd - d.debtUsd : 0;
        d.healthFactor = d.debtUsd == 0 ? type(uint256).max : Math.mulDiv(d.liquidationUsd, WAD, d.debtUsd);
        d.ltvUsed = d.collateralUsd == 0 ? 0 : Math.mulDiv(d.debtUsd, WAD, d.collateralUsd);
        d.risk = riskOf(d.healthFactor);
    }

    function _params(address asset) internal view returns (Params memory p) {
        (, uint8 dec,, uint256 ltv, uint256 lt,,,,,,,,) = pool.markets(asset);
        p = Params(dec, ltv, lt);
    }

    function _line(address user, address asset) internal view returns (AssetLine memory l) {
        Params memory p = _params(asset);
        l.asset = asset;
        l.ltv = p.ltv;
        l.liquidationThreshold = p.lt;
        l.supplied = pool.supplyBalance(asset, user);
        l.borrowed = pool.borrowBalance(asset, user);
        if (l.supplied == 0 && l.borrowed == 0) return l;
        l.price = pool.oracle().getPrice(asset);
        uint256 unit = 10 ** p.decimals;
        l.suppliedUsd = Math.mulDiv(l.supplied, l.price, unit);
        l.borrowedUsd = Math.mulDiv(l.borrowed, l.price, unit, Math.Rounding.Ceil);
    }

    /// @notice Categoría de riesgo para un HF.
    function riskOf(uint256 hf) public pure returns (Risk) {
        if (hf == type(uint256).max) return Risk.NoDebt;
        if (hf < WAD) return Risk.Liquidatable;
        if (hf < 1.1e18) return Risk.Danger;
        if (hf < 1.5e18) return Risk.Warning;
        return Risk.Safe;
    }

    // ------------------------------------------------------------------
    // Simulaciones "what-if"
    // ------------------------------------------------------------------

    /// @notice HF si el precio de `asset` fuese `newPrice` (resto constante).
    /// @dev El activo afecta tanto el lado colateral como el de deuda si el usuario tiene ambos.
    function hfAtPrice(address user, address asset, uint256 newPrice) public view returns (uint256) {
        uint256 n = pool.assetsCount();
        uint256 liq;
        uint256 debt;
        for (uint256 i; i < n; i++) {
            address a = pool.assetList(i);
            AssetLine memory l = _line(user, a);
            if (a == asset && (l.supplied > 0 || l.borrowed > 0)) {
                uint256 unit = 10 ** _params(a).decimals;
                l.suppliedUsd = Math.mulDiv(l.supplied, newPrice, unit);
                l.borrowedUsd = Math.mulDiv(l.borrowed, newPrice, unit, Math.Rounding.Ceil);
            }
            liq += Math.mulDiv(l.suppliedUsd, l.liquidationThreshold, WAD);
            debt += l.borrowedUsd;
        }
        return debt == 0 ? type(uint256).max : Math.mulDiv(liq, WAD, debt);
    }

    /// @notice HF ante caídas de `dropsBps[i]` (ej. 1000 = −10 %) en el precio de `asset`.
    function stressTest(address user, address asset, uint256[] calldata dropsBps)
        external
        view
        returns (uint256[] memory hfs)
    {
        uint256 p = pool.oracle().getPrice(asset);
        hfs = new uint256[](dropsBps.length);
        for (uint256 i; i < dropsBps.length; i++) {
            uint256 drop = dropsBps[i] > 10_000 ? 10_000 : dropsBps[i];
            hfs[i] = hfAtPrice(user, asset, (p * (10_000 - drop)) / 10_000);
        }
    }

    /// @notice Precio de `collAsset` al cual HF = 1, manteniendo todo lo demás constante.
    /// @dev Resolver  Σ_otros liqUsd + q·P*·lt = deuda  →  P* = (deuda − otros)/(q·lt).
    ///      Devuelve 0 si la posición no puede liquidarse por este activo (otros ya cubren),
    ///      y type(uint256).max si ya es liquidable con cualquier precio (q = 0 y deuda > otros).
    ///      Supone que el usuario no tiene deuda en `collAsset`.
    function liquidationPrice(address user, address collAsset) external view returns (uint256) {
        uint256 n = pool.assetsCount();
        uint256 others;
        uint256 debt;
        uint256 qty;
        uint256 lt;
        uint256 unit;
        for (uint256 i; i < n; i++) {
            address a = pool.assetList(i);
            AssetLine memory l = _line(user, a);
            debt += l.borrowedUsd;
            if (a == collAsset) {
                qty = l.supplied;
                lt = l.liquidationThreshold;
                unit = 10 ** _params(a).decimals;
            } else {
                others += Math.mulDiv(l.suppliedUsd, l.liquidationThreshold, WAD);
            }
        }
        if (debt <= others) return 0;
        if (qty == 0 || lt == 0) return type(uint256).max;
        // P* (USD WAD por unidad) = (deuda − otros) · unit · WAD / (qty · lt)
        return Math.mulDiv(debt - others, unit * WAD, qty * lt);
    }

    /// @notice Máximo adicional que puede pedir prestado de `asset` (respetando LTV y cash).
    function maxBorrow(address user, address asset) external view returns (uint256) {
        (, uint256 debt, uint256 limit,) = pool.accountData(user);
        if (limit <= debt) return 0;
        uint256 p = pool.oracle().getPrice(asset);
        uint256 amt = Math.mulDiv(limit - debt, 10 ** _params(asset).decimals, p);
        (,,,,,,,,,,,, uint256 cash) = pool.markets(asset);
        return amt < cash ? amt : cash;
    }

    /// @notice Máximo retirable de `asset` sin que HF < 1.
    function maxWithdraw(address user, address asset) external view returns (uint256) {
        (, uint256 debt,, uint256 liq) = pool.accountData(user);
        uint256 bal = pool.supplyBalance(asset, user);
        if (debt == 0) return bal;
        if (liq <= debt) return 0;
        Params memory pr = _params(asset);
        uint256 p = pool.oracle().getPrice(asset);
        // liq − x·p·lt ≥ debt  →  x ≤ (liq − debt)/(p·lt)
        uint256 x = Math.mulDiv(liq - debt, 10 ** pr.decimals * WAD, p * pr.lt);
        return x < bal ? x : bal;
    }

    // ------------------------------------------------------------------
    // Monitoreo por lotes
    // ------------------------------------------------------------------

    struct Summary {
        address user;
        uint256 healthFactor;
        uint256 debtUsd;
        Risk risk;
    }

    /// @notice HF y riesgo de muchas cuentas en una sola llamada (para bots/alertas).
    function batch(address[] calldata users) external view returns (Summary[] memory out) {
        out = new Summary[](users.length);
        for (uint256 i; i < users.length; i++) {
            (, uint256 debt,, uint256 liq) = pool.accountData(users[i]);
            uint256 hf = debt == 0 ? type(uint256).max : Math.mulDiv(liq, WAD, debt);
            out[i] = Summary(users[i], hf, debt, riskOf(hf));
        }
    }
}
