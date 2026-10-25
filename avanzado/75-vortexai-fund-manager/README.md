# 75 · VortexAI — Fondo gestionado por un agente IA dentro de una DAO — Avanzado

Fondo on-chain que provee liquidez en un **par volátil (WETH/USDC)**. Un **agente IA** decide cuánta liquidez poner según el mercado, pero solo dentro de **guardarraíles** que fija una **DAO** de depositantes, que a su vez está acotada por una **constitución** inmutable.

> **La IA propone, el contrato limita.**

| Contrato | Rol |
|---|---|
| `VortexVault` | Shares VTX (ERC20Votes), NAV con *fair LP pricing*, política paramétrica, ejecución con guardas, retiro in-kind, pausa. |
| `VortexDAO` | Propuestas restringidas a `setParams`, `setAgent` y `unpause`. Snapshot, quórum 10%, timelock de 1 día. |
| `Mocks.sol` | AMM x·y=k (0,3% fee) con LP ERC-20, oráculo y tokens. |

## La "IA": dos capas

### 1. Política paramétrica on-chain (determinista y auditable)

```
vol    = EWMA(|Δprecio oráculo| por hora)          α = 20%
target = clamp(maxLp − volK · vol / 1e4, minLp, maxLp)   [bps del NAV en LP]
```

El fundamento es que el *impermanent loss* crece con la volatilidad (≈ σ²/8 por período en un x·y=k). Con más volatilidad conviene menos LP y más USDC. Con vol 0 el target es 80%. Con 1% por hora baja a 50%, y con vol ≥ 2% queda en el piso de 20%.

### 2. Agente off-chain (documentado, no implementado)

- **Entradas**: precios y volúmenes del pool, funding rates, volatilidad implícita de opciones (Deribit) y sentimiento (noticias).
- **Modelo**: LLM con herramientas o un agente de RL entrenado sobre backtests de IL contra fees.
- **Salida**: `aiTargetBps`, enviado con `rebalance(aiTargetBps)` desde la wallet del agente. Idealmente esa wallet corre en un TEE atestado (ver el proyecto 73) para probar qué modelo firmó.
- El contrato **rechaza** cualquier target fuera de `policy ± aiBand` o de `[minLp, maxLp]`. En el peor caso, un agente comprometido solo puede mover la asignación dentro de la banda.

## Guardarraíles

| Capa | Quién la fija | Qué limita |
|---|---|---|
| Constitución (`HARD_*`) | Código inmutable | LP ≤ 90%, slippage ≤ 3%, desvío ≤ 5%, trade ≤ 50% del NAV |
| `Params` | DAO (votación + timelock) | Banda de la IA, slippage, desvío, tamaño, cooldown |
| Agente | Modelo off-chain | Solo `aiTargetBps` dentro de la banda |
| Guardián | Multisig de emergencia | Solo puede **pausar** (despausar es de la DAO) |

En `rebalance`, antes de operar:

1. **Desvío spot vs oráculo** ≤ `maxDeviationBps`. Si alguien manipuló el AMM, no se opera.
2. **Slippage**: cada swap tiene `minOut` calculado con el precio del oráculo.
3. **Tamaño**: como máximo `maxTradeBps` del NAV por llamada, con `cooldown` entre llamadas.

## Seguridad económica

- **Fair LP pricing**: el LP se valúa como `2·√(k·p_oráculo)` y no con reservas spot. Mover el pool no infla el NAV (clase de ataque Warp Finance o Cheese Bank). Lo verifica `test_ManipulationGuard`.
- **Retiro in-kind**: `redeem` entrega USDC y WETH pro-rata **sin usar el oráculo**, así que la salida no se puede manipular. Funciona **aunque el fondo esté pausado**.
- **Ataque de inflación**: shares virtuales (1e3). Lo verifica `test_InflationAttackUnprofitable`.
- **Gobernanza**: snapshot de votos (anti flash loan), timelock, y la DAO **no puede hacer llamadas arbitrarias** (whitelist de selectores) ni romper la constitución.

## Tests (16)

| Test | Qué demuestra |
|---|---|
| `test_RebalanceUpInCappedSteps` | 0 → 50% → 80% respetando el tope por paso |
| `test_HighVolatilityReducesLp` | Más vol ⇒ política al 20% ⇒ desarma LP |
| `test_AiFineTuneWithinBand` / `test_RevertWhen_AiOutOfBand` | La banda de la IA funciona |
| `test_ManipulationGuard` | NAV estable y rebalanceo bloqueado ante manipulación |
| `test_RedeemInKindEvenWhenPaused` | Salida garantizada |
| `test_DaoChangesParams` / `test_DaoReplacesAgent` | Gobierno real |
| `test_DaoCannotBreakConstitution` / `test_RevertWhen_DaoArbitraryCall` | Límites de la DAO |
| `test_PauseOnlyGuardianUnpauseOnlyDao`, `test_RevertWhen_*` | Control de acceso |

## Limitaciones

- AMM, oráculo y tokens son mocks (los dos tokens usan 18 decimales). En producción: Uniswap V2/V3, Chainlink más un TWAP como segunda fuente, y USDC de 6 decimales.
- `poke` mide la vol con el oráculo una vez por hora. Si nadie llama, la vol queda desactualizada (conviene un keeper).
- Los depósitos usan el NAV del oráculo: si el oráculo se desvía, un depositante podría entrar barato. Mitigación: fee de entrada o el mismo chequeo de desvío en `deposit`.
- Sin fees de gestión ni performance.
- El agente off-chain se documenta, no se incluye: el diseño hace que su calidad afecte el **rendimiento**, pero no la **seguridad** de los fondos.
