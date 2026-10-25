# 16 · Position Manager (multi-protocolo con rebalanceo)

**Nivel:** Avanzado

Un gestor de cartera on-chain para **un activo**, por ejemplo USDC, repartido entre varios
protocolos de rendimiento según pesos objetivo. Cuando la cartera se desvía (porque un
protocolo rindió más, o porque entró o salió plata), un keeper la rebalancea con control de
pérdidas.

## Contratos

| Archivo | Rol |
|---|---|
| `src/PositionManager.sol` | Registro de venues, pesos objetivo, depósito y retiro en cascada, `rebalance` y `emergencyExit`. |
| `src/venues/IVenue.sol` | Interfaz uniforme: `totalAssets`, `maxWithdraw`, `deposit`, `withdraw`. |
| `src/venues/VenueBase.sol` | Manager inmutable y `onlyManager`. |
| `src/venues/LendingPoolVenue.sol` | Supply en el LendingPool del proyecto 09. Solo deposita, nunca pide prestado, así que la posición no puede liquidarse. |
| `src/venues/ERC4626Venue.sol` | Cualquier vault ERC-4626. Un solo adaptador sirve para todo el ecosistema. |
| `src/protocol/*` | Copia del pool del proyecto 09. |
| `src/mocks/MockYieldVault.sol` | Vault ERC-4626 con `simulateYield` y `simulateLoss`. |
| `src/mocks/LossyVenue.sol` | Venue con un fee de salida oculto. |

## Diseño

- **Patrón adaptador:** el manager no sabe nada de Aave, Morpho o Yearn, solo habla con
  `IVenue`. Cada venue custodia la posición a nombre de **un** manager inmutable.
- **Pesos en bps:** `Σ pesos ≤ 10 000`. Lo que falta para llegar a 10 000 es el **colchón
  líquido**, que permite retirar sin tocar ningún protocolo.
- **El rebalanceo se hace en dos fases:**
  1. Retira el excedente de los venues sobreponderados, limitado por `maxWithdraw`.
  2. Deposita en los subponderados con lo que haya en el colchón.

  Hacer los retiros primero garantiza que siempre haya liquidez para depositar.
- **Retiro en cascada:** saca primero del colchón y después de cada venue en orden,
  respetando la liquidez disponible. Si el pool de lending está al 100 % de utilización,
  `maxWithdraw` es 0 y el retiro cae al siguiente venue.

## Incentivos y parámetros

| Parámetro | Default | Para qué |
|---|---|---|
| `driftThresholdBps` | 200 (2 %) | Evita rebalanceos inútiles: cada movimiento cuesta gas y fees. |
| `cooldown` | 1 h | Limita la frecuencia de rebalanceo. El primer rebalanceo no espera. |
| `maxLossBps` | 10 (0,1 %) | Si el rebalanceo destruye más valor que esto, revierte. |
| `keeper` | — | Bot que rebalancea. Puede mover fondos, pero no retirarlos. |

## Ataques y riesgos

| Riesgo | Mitigación | Test |
|---|---|---|
| Keeper malicioso o buggeado que rebalancea en loop para quemar valor en fees | umbral + cooldown + `maxLossBps` | `test_CooldownAndNoOp`, `test_LossyVenueBlocksRebalance` |
| Venue con fee de salida o slippage ocultos | chequeo de valor antes y después | `test_LossyVenueBlocksRebalance` |
| Hackeo de un protocolo | `emergencyExit`: sale con lo que haya y pone el peso en 0 | `test_EmergencyExit` |
| Protocolo ilíquido (utilización 100 %) | `maxWithdraw` + cascada | `test_WithdrawFallsThroughIlliquidVenue` |
| Venue de otro activo | `WrongAsset` en `addVenue` | `test_ConfigValidation` |
| Llamar al venue directo | `onlyManager` | `test_AccessControl` |
| DoS por demasiados venues | `MAX_VENUES = 8` | — |
| Venue que miente en `totalAssets` | **Sin defensa técnica**: el owner tiene que auditar cada venue antes de agregarlo. `maxLossBps` mide con esos mismos números, así que no sirve contra esto. | — |

El fuzz `testFuzz_RebalanceConservesValue` aplica rendimientos aleatorios a los vaults y
verifica que el rebalanceo conserva el valor total (±5 unidades por redondeo) y deja la
cartera dentro del umbral.

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
