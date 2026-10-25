# 25 · Perpetual Futures: funding por skew, margen y liquidaciones

**Nivel:** Avanzado. Es la base de los proyectos 24 (delta-neutral) y 29 (arbitraje de funding).

`PerpMarket` es un perpetuo de un solo mercado (ETH-USD) con margen en USDC, en el modelo
**"pool como contraparte"** (estilo GMX y Synthetix Perps v2): no hay libro de órdenes, se
opera al precio del oráculo y el pool de LPs toma el lado contrario del **skew neto**.

## Diseño

| Pieza | Detalle |
|---|---|
| Posición | `size` (WAD, positivo para long y negativo para short), precio de entrada promedio y `fundingEntry` |
| Margen | USDC por cuenta, aislado por mercado |
| Margen inicial / mantenimiento | 10 % (10x máx.) / 5 % |
| Trading fee | 0,05 % del notional: 80 % a los LPs y 20 % al fondo de seguro |
| Liquidación | Cualquiera puede ejecutarla. El liquidador cobra el 1 % del notional (con tope en el equity que quede) y el resto va al seguro |
| Deuda incobrable | La cubre primero el fondo de seguro y después los LPs |
| Pool LP | Shares con offset virtual. `poolValue = caja − PnL abierto + funding adeudado` |
| Skew cap | El valor de \|skew\|·precio no puede superar el valor del pool, ni al operar ni al retirar como LP |

### Funding basado en skew

```
skew = longOI − shortOI
rate/seg = clamp(maxFunding · skew / skewScale, ±maxFunding)
fundingIndex += rate · precio · dt          (USD que paga 1 ETH long)
funding adeudado de una posición = size · (index_now − index_entry)
```

Con más longs que shorts los longs pagan, y viceversa. La contraparte del skew es el pool,
así que el funding termina en los LPs. El **incentivo** es que, si el skew es grande, abrir
del lado minoritario **cobra** funding. Ese es el negocio del arbitrajista del proyecto 29 y
del vault delta-neutral del 24, y es lo que empuja al mercado hacia el equilibrio y reduce
el riesgo del pool.

### Contabilidad O(1)

Para calcular el PnL y el funding de todos los traders no hace falta iterar. Alcanza con
mantener tres agregados:

- `netSize`
- `Σ size·entry`
- `Σ size·fundingEntry`

Con ellos:

```
PnL traders     = netSize·P − Σ size·entry
funding traders = netSize·idx − Σ size·fundingEntry
```

Los agregados se actualizan restando la contribución vieja y sumando la nueva con la misma
fórmula, así que no se acumula error de redondeo. El fuzz verifica que la caja cuadre al
wei.

### Redondeo

Todas las conversiones de USD (WAD) a USDC redondean hacia −∞ (`_toUsdcFloor`), o sea,
siempre a favor del pool. Por eso el polvo de redondeo nunca se puede extraer.

## Ataques y defensas

| Riesgo | Defensa |
|---|---|
| **Front-running del oráculo** (operar sabiendo el próximo precio) | `acceptablePrice` protege al usuario, pero no al pool. En producción se usan órdenes en dos pasos (commit, y ejecución con el precio siguiente, como Synthetix y GMX) o un oráculo pull (Pyth) con *staleness* corto. **Limitación conocida de este ejemplo.** |
| Manipulación del oráculo | El oráculo es un mock administrado y usa `maxAge`. En producción se combina Chainlink con un TWAP y un circuit breaker. |
| Skew excesivo que quiebra al pool | Skew cap respecto de `poolValue`, aplicado también a los retiros de LPs. |
| Cascada de liquidaciones / deuda incobrable | El margen de mantenimiento da colchón, hay premio para que los keepers liquiden rápido y el fondo de seguro absorbe antes que los LPs. |
| Abusar del funding (abrir justo antes de un accrue) | El funding es continuo (`accrueFunding` al principio de cada acción) y no hay snapshots discretos que se puedan *jugar*. |
| Retirar margen y quedar al borde | `withdrawMargin` exige margen **inicial**, no el de mantenimiento. |
| Quedar atrapado | Reducir una posición está permitido siempre, aunque el equity esté por debajo del margen inicial. |
| Inflación de shares de LP | Offset virtual de 1e6 en `lpDeposit` y `lpWithdraw`. |
| Reentrancy | `nonReentrant` en todas las funciones externas que mueven fondos. |

## Tests (`test/PerpMarket.t.sol`, 15)

- **PnL:** ganancia en long, short con cierre parcial y *flip*, precio de entrada promedio.
- **Funding:**
  - pago de longs al pool;
  - mercado balanceado que da 0, y los shorts que pagan cuando el skew es negativo;
  - tope en el máximo;
  - `poolValue` que incluye el PnL abierto y el funding.
- **Márgenes:** margen inicial y retiro, slippage, y reducir posiciones siempre permitido.
- **Liquidación:** premio y seguro, `liquidationPrice` ≈ 1843, deuda incobrable que absorben
  el seguro y luego los LPs.
- **Pool:** skew cap en pools chicos (también al retirar), y el LP que gana cuando los
  traders pierden.
- **Fuzz:** conservación de la caja con precios, tiempos y tamaños aleatorios.

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
