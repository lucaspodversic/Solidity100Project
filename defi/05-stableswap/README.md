# 05 · Stableswap (estilo Curve)

**Nivel:** Avanzado

Pool de N monedas (2 a 4) para activos que deberían valer lo mismo (USDC/USDT/DAI), con el
invariante StableSwap de Curve, amplificación `A` con rampa gradual, comisión de swap,
comisión por desbalance y retiro en una sola moneda.

## Contrato

`src/StableSwapPool.sol` (el pool es también el token LP, ERC-20).

| Función | Descripción |
|---|---|
| `exchange(i, j, dx, minDy)` | Swap de la moneda `i` a la `j` con protección de slippage. |
| `getDy(i, j, dx)` | Cotización exacta (con comisión). |
| `addLiquidity(amounts, minMint)` | Depósito balanceado o desbalanceado; LP ∝ aumento de D. |
| `removeLiquidity(lp, mins)` | Retiro proporcional sin comisión. |
| `removeLiquidityOneCoin(lp, i, min)` / `calcWithdrawOneCoin` | Retiro en una sola moneda (paga comisión por desbalance). |
| `getVirtualPrice()` | `D / supply`: valor de 1 LP; solo crece con comisiones. |
| `rampA(futureA, futureTime)` | El owner cambia `A` linealmente (máx. x10, mínimo 1 día). |

## Diseño

El invariante es

```
A·nⁿ·Σxᵢ + D = A·D·nⁿ + Dⁿ⁺¹ / (nⁿ·Πxᵢ)
```

- Con `A` grande domina la **suma constante** (precio 1:1, casi sin slippage).
- Con `A → 0` domina el **producto constante** (como Uniswap), que nunca se queda sin liquidez.
- `D` se resuelve con **Newton** (`getD`) y el nuevo saldo `y` de la moneda de salida
  con otra iteración de Newton (`_getY` / `_getYD`), con convergencia a 1 wei.
- Los saldos se **normalizan a 18 decimales** con `rates[i] = 10^(18−decimales)`, así USDC
  (6) y DAI (18) conviven.
- La salida de cada swap se redondea **1 wei a favor del pool**.

## Incentivos económicos

- Los LP cobran la comisión de swap (0,04 % en los tests), que queda dentro del pool y sube el
  `virtual price`.
- Cuando el pool se desbalancea, la moneda escasa se paga con prima. Eso incentiva a los
  arbitrajistas a reequilibrarlo.
- Los depósitos y retiros desbalanceados pagan `fee·n/(4(n−1))` sobre la desviación, porque
  equivalen a un swap implícito.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Swap "gratis" depositando la moneda X y retirando la Y en una sola moneda | Comisión por desbalance en ambos pasos (test `DepositThenWithdrawOneCoinIsNotFreeSwap`). |
| Cambiar `A` de golpe para mover precios y arbitrar contra los LP | `rampA` lineal, con límite x10 y mínimo 1 día. |
| Sandwich / front-running | `minDy`, `minMint` y `minAmounts` en todas las operaciones. |
| Errores de redondeo explotables con ida y vuelta | Redondeo a favor del pool (fuzz `RoundTripNoProfit`). |
| Reentrancia con tokens con hooks | `nonReentrant`, y los efectos se aplican antes de las transferencias. |
| Disminuir el valor del LP | Fuzz `VirtualPriceMonotonic`: el virtual price nunca baja con swaps. |

## Limitaciones

- No hay comisión de admin, oráculos ni soporte para tokens *fee-on-transfer* o *rebasing*.
- Newton puede no converger en estados extremos; en ese caso revierte (`DidNotConverge`).

## Tests

14 tests (2 de fuzz). Cubren:
- el mint inicial igual a D;
- slippage mínimo cerca del peg y la comparación contra x·y=k;
- swaps entre monedas con distintos decimales;
- la comisión por desbalance y el ataque de depósito + retiro;
- la rampa de A y el control de acceso.


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
