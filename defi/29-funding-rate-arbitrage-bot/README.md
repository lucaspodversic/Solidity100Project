# 29 · Funding Rate Arbitrage Bot (contrato + script)

**Nivel:** Avanzado

En este proyecto, `FundingArbBot` arbitra el **funding** entre dos perpetuos del mismo activo
(venues A y B, ambos copias del `PerpMarket` del proyecto 25). Cuando un venue cobra a los
longs mucho más que el otro, el bot hace dos cosas:

- abre un **short en el venue caro y un long en el barato** por el mismo tamaño, lo que deja
  la exposición al precio en ≈ 0;
- cobra el *spread* de funding × notional × tiempo, y cierra cuando el spread converge.

## Piezas

| Archivo | Rol |
|---|---|
| `src/FundingArbBot.sol` | Bóveda del bot. Tiene vistas de decisión (`spreadPerDay`, `previewEdge`, `shouldOpen`, `shouldClose`, `needsRebalance`, `totalEquity`) y acciones (`open`, `close`, `rebalance`). |
| `src/perp/PerpMarket.sol` | Copia del proyecto 25, con funding lineal en el skew y acotado. |
| `src/oracle/PriceOracle.sol`, `src/mocks/MockERC20.sol` | Copias locales: cada proyecto es independiente. |
| `script/DemoFundingArb.s.sol` | Simulación local completa: despliegue, desbalanceo de venues, loop de keeper cada 8 h, convergencia y salida. |
| `script/Keeper.s.sol` | Una iteración contra un despliegue real, pensada para correr por cron con `--broadcast`. |

## Cómo gana plata (números del test)

Escenario:

- A tiene un skew de +200 ETH, así que su funding es +1 %/día (tope) y pagan los longs.
- B tiene un skew de −100 ETH, así que su funding es −1 %/día y pagan los shorts.
- El spread es del 2 %/día.

El bot abre 50 ETH por leg (100k USD, con 50k de margen en cada uno):

- **Sus propios trades comprimen el spread.** A queda en 150 (sigue en el tope, 1 %) y B queda
  en −50 (−0,5 %). El edge real es del **1,5 %/día**. `previewEdge(size)` lo predice
  exactamente antes de operar.
- En 1 día cobra 1000 en A y 500 en B, menos 4 fees de 50, lo que da **+1300 USDC**
  (`test_EarnsFundingThenCloses`).
- **Precio:** con ±20 % de movimiento, o en un fuzz entre 1500 y 2600, el equity total no
  cambia (±2 wei). Lo que pierde un leg lo gana el otro.

El demo (`forge script script/DemoFundingArb.s.sol -vv`) sigue esta secuencia:

1. Abre con un edge de 149 bps/día y mantiene la posición unas 40 h.
2. El whale de A cierra y el spread se va a 0.
3. El bot cierra solo, con un **PnL de +2299 USDC**.
4. Al salir, el skew de B vuelve a −100 y el spread observable sube al 1 %. Aun así
   `shouldOpen` **no** reabre, porque `previewEdge` muestra que reabrir dejaría el edge en 0.
   Sin el preview, el bot entraría en un loop de abrir y cerrar pagando fees.

## Incentivos

- Para los venues, el funding basado en skew es **un pago a quien equilibre el mercado**. El
  bot es justamente ese actor y, al operar, empuja los dos funding hacia cero. Es la fuerza
  que hace converger los precios y las tasas entre exchanges.
- El arbitraje se agota solo: cuanto más grande la posición, menos spread queda. El tamaño
  óptimo es el que maximiza edge × notional, no el máximo posible.

## Riesgos y defensas

| Riesgo | Defensa en el contrato |
|---|---|
| **Margen aislado por venue.** Con +50 %, el short se liquida aunque el long gane lo mismo. | `minMarginBps` (≤ 3x por leg), `needsRebalance` (equity < 15 % del notional) y `rebalance`, que mueve margen del leg ganador al perdedor. El venue exige que el leg de origen siga sobre su margen inicial. Test: con +40 % se rebalancea y con +50 % sigue vivo. |
| Un leg liquidado deja el otro **desnudo** (exposición direccional). | `shouldClose()` se vuelve true y **cualquiera** puede llamar a `close()`. Test: la liquidación con +47,5 % cuesta 2623 USDC (el equity remanente de A y las fees), no la posición entera. |
| Key del operador comprometida | El operador **no puede retirar**: solo el owner, que debería ser una multisig. El operador además está acotado por `maxSizePerLeg`, el margen mínimo, la desviación de precio y la regla de spread posterior. Lo peor que puede hacer es abrir o cerrar en mal momento y quemar fees. |
| Slippage / oráculo movido entre la decisión y la tx | `refPrice` + `maxDevBps`, que se traducen además a los `acceptablePrice` del venue. |
| Auto-arbitraje que destruye el edge | `open` revierte con `SpreadTooLowAfter` si el edge posterior es menor que `exitSpreadPerDay`. `shouldOpen(size)` usa el mismo cálculo. |
| Bot caído con un spread que se dio vuelta | Si `edgePerDay < exit`, cualquiera puede cerrar. |
| Reentrancy | `nonReentrant` en `open`, `close` y `rebalance`. Los venues son contratos conocidos e inmutables. |

**Limitaciones (mocks):**

- Los dos venues comparten el oráculo, así que el delta es exactamente 0. Con oráculos o mark
  prices distintos aparece *basis risk*: los precios de los dos legs pueden divergir.
- No se modelan los costos de bridging ni de gas entre cadenas. En la práctica los venues
  suelen estar en cadenas distintas y el rebalanceo no es atómico.
- El funding futuro es incierto: el edge observado puede desaparecer al minuto siguiente.

## Tests (`test/FundingArbBot.t.sol`, 10)

- Spread, dirección y preview exacto.
- Revierte por debajo del umbral de entrada.
- Revierte si el propio trade mata el spread.
- Límites y roles.
- Neutralidad de precio.
- Funding cobrado y cierre.
- Convergencia: cierre permisionless.
- El rebalanceo salva el short.
- Leg liquidado: el otro se cierra por cualquiera.
- Fuzz de neutralidad.

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
