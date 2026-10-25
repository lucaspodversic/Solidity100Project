# 67 · Stablecoin colateralizada (CDP) con tasa dinámica — Avanzado

Un motor de deuda colateralizada **estilo MakerDAO simplificado**: se deposita WETH y se acuña **USD100**, una stablecoin que apunta a $1.

| Ruta | Qué hay |
|---|---|
| `src/CDPEngine.sol` | Vaults, ratios, interés compuesto con acumulador, tasa dinámica, liquidaciones y deuda incobrable. |
| `src/Stablecoin.sol` | ERC-20 con mint y burn reservados al engine. |
| `src/Mocks.sol` | WETH y oráculos estilo Chainlink. |
| `test/CDPEngine.t.sol` | 17 tests, incluido un fuzz del invariante oferta ≈ deuda. |

## Parámetros

| Parámetro | Valor | Para qué |
|---|---|---|
| MCR | 150% | Ratio mínimo para acuñar o retirar. |
| LT | 130% | Por debajo de este ratio se puede liquidar. El colchón de 20% le da tiempo al usuario. |
| Bonus de liquidación | 10% | Incentivo para los liquidadores. |
| Close factor | 50% | Liquidaciones parciales: evita sobre-liquidar. |
| DUST | 100 USD100 | Deuda mínima por vault: que siempre convenga liquidarlo. |
| Tasa base | 2% anual | |
| Sensibilidad | +2% anual por cada 1% bajo el peg | Ver la política abajo. |
| Rango de la tasa | 0%–50% | |
| Staleness del oráculo | 1 h | |

## Política de tasa dinámica

`updateRate()` es permissionless: cualquiera puede llamarla.

- **USD100 < $1** (hay exceso de oferta): la tasa sube y la deuda se encarece. Los deudores compran USD100 en el mercado para repagar, la demanda sube y el precio vuelve a $1.
- **USD100 > $1** (hay escasez): la tasa baja. Acuñar se abarata, aumenta la oferta y el precio baja.

Siempre se hace `drip()` con la tasa vieja antes de cambiarla, así el interés ya devengado no cambia de forma retroactiva.

## Intereses (acumulador)

- Cada vault guarda `normDebt`, y su deuda real es `normDebt × rateAcc / RAY`.
- `drip()` actualiza `rateAcc` en O(1) para todos y **acuña la diferencia al treasury**. Por eso siempre se cumple `totalSupply(USD100) ≈ totalDebt` (ver el test fuzz).
- Los redondeos van **a favor del protocolo**: la deuda se redondea hacia arriba.

## Liquidación

```
ratio < 130%  →  el liquidador quema X USD100  →  recibe X/precio × 1,10 de colateral
```

Si el colateral no alcanza, el liquidador se lleva todo el colateral y la deuda remanente se registra en `badDebt`. En producción eso se cubre con el superávit del treasury o con una subasta de un token de gobernanza (MKR), como hace Maker.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Manipular el precio con un flash loan | Feed externo tipo Chainlink, no un precio spot de un AMM. |
| Oráculo caído o congelado | `StalePrice` si tiene más de 1 h. `BadPrice` si es ≤ 0. |
| Retirar colateral dejando el vault insolvente | Se chequea el MCR después de modificar el estado. |
| Vaults "polvo" que no conviene liquidar | `DUST`. |
| Sobre-liquidar a un usuario | Close factor del 50%. |
| Reentrada vía token | `nonReentrant` más CEI. |
| Emisión infinita | `debtCeiling`, y mint/burn solo desde el engine. |
| Espiral de liquidaciones | Colchón MCR/LT, liquidaciones parciales. Es un riesgo sistémico documentado. |

## Limitaciones

- Un solo colateral y una sola tasa global (Maker usa *ilks* con un parámetro por colateral).
- Sin subastas: las liquidaciones son a precio fijo con bonus.
- No hay PSM (módulo de estabilidad del peg). Un PSM USDC↔USD100 1:1 anclaría el precio mucho más fuerte.
- `pegFeed` debería ser un TWAP de un pool profundo o un feed agregado.
