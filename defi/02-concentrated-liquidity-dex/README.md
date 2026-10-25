# 02 · Concentrated Liquidity DEX (estilo Uniswap V3)

**Nivel:** Avanzado

Pool de liquidez concentrada: cada LP elige un rango de precios `[tickLower, tickUpper)` y su
capital solo provee liquidez (y cobra comisiones) mientras el precio esté dentro de ese rango.

## Contratos

| Archivo | Rol |
|---|---|
| `src/ConcentratedPool.sol` | Pool: `initialize`, `mint`, `burn`, `collect`, `swap` (exact-in con límite de precio). |
| `src/libraries/TickMath.sol` | `precio(t) = 1.0001^t`; conversión tick ↔ `sqrtPriceX96` (implementación propia por exponenciación binaria + búsqueda binaria). |
| `src/libraries/LiquidityMath.sol` | Fórmulas `Δx = L·(√Pb−√Pa)/(√Pa·√Pb)`, `Δy = L·(√Pb−√Pa)` y precio siguiente tras un input. |

## Diseño

- **Estado:** `sqrtPriceX96` (Q64.96), `tick` actual, `liquidity` activa.
- **Ticks:** cada borde guarda `liquidityNet` (cuánto cambia L al cruzarlo) y `feeGrowthOutside`.
- **Swap:** bucle por tramos. En cada tramo la liquidez es constante; se avanza hasta el próximo
  tick inicializado o hasta agotar la entrada; al cruzar se aplica `liquidityNet` y se invierten
  los acumuladores "outside".
- **Comisiones:** `feeGrowthGlobal += fee · 2^128 / L`. Las comisiones dentro de un rango se
  obtienen como `global − below − above`, el truco de V3 que permite cobrar en O(1) sin iterar.

## Incentivos económicos

- **Eficiencia de capital:** con la misma `L`, un rango de ±1 % requiere una fracción del capital
  que el rango completo (test `test_ConcentratedIsMoreCapitalEfficient`). Los LP activos ganan
  más comisiones por dólar.
- **Riesgo:** fuera de rango la posición queda 100 % en el activo que se depreció y no cobra
  comisiones; la pérdida impermanente es mayor cuanto más estrecho el rango.
- **Competencia:** los LP compiten por concentrarse cerca del precio; quienes no rebalancean
  pierden participación en las comisiones (ver proyecto 16, Position Manager).

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Sandwich | `amountOutMin` + `sqrtPriceLimitX96`. |
| JIT liquidity (añadir liquidez justo antes de un swap grande y retirarla después) | No se impide (tampoco en V3); se documenta: es una transferencia de comisiones entre LP, no robo al trader. |
| Extracción por redondeo | Todo lo que entra al pool se redondea hacia arriba y lo que sale hacia abajo. |
| Reentrancia | `ReentrancyGuard` en `mint`, `burn`, `collect`, `swap`. |
| DoS por muchos ticks | Limitación conocida: el arreglo ordenado es O(n). En producción se usa un bitmap. |
| Overflow de acumuladores | Las restas de `feeGrowth` son modulares (`unchecked`) por diseño, igual que V3. |

## Simplificaciones respecto de V3

Sin NFT de posiciones, sin oráculo de observaciones, sin protocol fee, pago por `transferFrom`
(en lugar de callback), rango de ticks ±400.000 y TickMath propio (menos preciso, verificado por
fuzz de ida y vuelta y monotonicidad).

## Tests (17)

TickMath (valor conocido, ida-vuelta y monotonicidad con fuzz), mint dentro/encima/debajo del
rango, ticks inválidos, burn, swaps en ambos sentidos, slippage, eficiencia de capital, cruce de
ticks, comisiones solo para posiciones en rango, límite de precio y fuzz de solvencia.

## Cómo compilar y testear

Requisitos: [Foundry](https://book.getfoundry.sh/) (`curl -L https://foundry.paradigm.xyz | bash && foundryup`).

Las dependencias (`forge-std` y `openzeppelin-contracts` v5.1.0) están vendorizadas en `../lib`
(compartidas por todos los proyectos del lote DeFi). Desde esta carpeta:

```bash
forge build          # compila
forge test -vv       # corre todos los tests (unitarios + fuzz)
forge test --gas-report
```

Si querés usar la carpeta de forma aislada (fuera de `defi/`), instalá las dependencias localmente
y ajustá `libs`/`remappings` en `foundry.toml` a `lib/`:

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
```

> Código educativo, no auditado. No lo uses en mainnet con fondos reales sin una auditoría profesional.
