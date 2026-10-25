# 17 · DeFi Position Simulator (contrato `pure` + script)

**Nivel:** Intermedio

Simulador determinístico de posiciones DeFi escrito como contrato **`pure`**. Se consulta gratis
con `eth_call` desde un frontend o un bot, y el script de Foundry imprime los escenarios en la
consola. No usa estado ni toca protocolos reales: todo es matemática reproducible.

## Qué simula

| Función | Pregunta que responde |
|---|---|
| `simulate(params, moves)` | ¿Cómo evoluciona mi préstamo con estos movimientos de precio? Cada paso aplica intereses, mueve el precio y, si HF < 1, hace **una liquidación parcial** con close factor y bonus. Si el colateral no alcanza, se confisca todo y la deuda que queda es incobrable. |
| `leverageLoop(equity, ltv, n)` | ¿Qué apalancamiento consigo con *n* vueltas de depositar → pedir → re-depositar? Converge a `1/(1−ltv)`. |
| `liquidationPrice(col, debt, lt)` | ¿A qué precio me liquidan? `deuda / (col·lt)` |
| `netApr(col, debt, sApr, bApr)` | APR neto sobre el capital propio, que puede ser negativo si el carry es malo. |
| `lpValueRatio(r)` | Valor de una posición LP x·y=k frente a HODL si el precio se multiplica por *r*: `2√r/(1+r)`. |

Cada paso de `simulate` devuelve una `Snapshot` con precio, colateral, deuda, HF, equity (con
signo), si hubo liquidación y cuánto colateral se confiscó.

## Diseño

- **Orden en cada paso:** intereses, precio y liquidación. Es el mismo orden que ve un
  protocolo real cuando un bot llega al bloque siguiente.
- **Interés simple por intervalo, compuesto entre intervalos:** 12 pasos mensuales al 12 % dan
  ≈ 12,68 %, igual que el `accrue` de Aave o Compound (ver `test_CompoundingAcrossSteps`).
- **Liquidaciones parciales:** con close factor del 50 %, una posición apalancada puede
  liquidarse **varias veces** en una caída larga, y cada vez paga el bonus. El script lo
  muestra claramente.
- **Propiedad verificada por fuzz:** una liquidación parcial mejora el HF **solo si** el
  colateral vale más que `deuda·(1+bonus)`. Por debajo de eso, liquidar empeora la posición.
  Por eso los protocolos exigen `lt·(1+bonus) < 1`.

## Script

```bash
forge script script/Simulate.s.sol -vv
SIM_DROP_BPS=1200 SIM_DAYS=5 forge script script/Simulate.s.sol -vv   # −12 %/día durante 5 días
```

Salida resumida con el default (−8 % por día durante 7 días):

```
=== LTV objetivo (%): 30   liq. price USD: 726   → sobrevive (HF 1,53 el día 7)
=== LTV objetivo (%): 50   liq. price USD: 1192  → liquidada el día 7
=== LTV objetivo (%): 70   liq. price USD: 1599  → 4 liquidaciones; equity 15 291 → 603 USD
IL con precio x2 (bps): 572
```

## Incentivos, ataques y limitaciones

- El simulador **no** modela slippage del liquidador, cambios de tasas por utilización ni
  oráculos con retraso. Esos efectos empeoran los resultados reales, así que hay que tomar los
  números como una **cota optimista**.
- Al ser `pure` no tiene superficie de ataque. El riesgo está en *usarlo mal*: decidir el
  tamaño de una posición sin estresar escenarios de cola, como −40 % en un día.
- Los parámetros inválidos revierten con `BadParams`, por ejemplo `liqThreshold ≥ 1` o
  `ltv ≥ 1` en el loop.

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
