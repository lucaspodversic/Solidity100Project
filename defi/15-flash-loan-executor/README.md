# 15 · Flash Loan Executor (recetas modulares con adapters)

**Nivel:** Avanzado

Un contrato **executor** que pide un flash loan ERC-3156 y ejecuta una **receta**: una lista
ordenada de pasos, cada uno a cargo de un *adapter* (swap, verificación de saldo o llamada
genérica). Al final repaga el préstamo más el fee, exige una ganancia mínima y manda el
excedente al owner. Es el patrón de herramientas tipo "DeFi Saver" o "Furucombo".

## Contratos

| Archivo | Rol |
|---|---|
| `src/FlashLoanExecutor.sol` | Orquestador. Tiene whitelists de adapters y lenders, el callback `onFlashLoan`, la liquidación final y `sweep`. |
| `src/adapters/IAdapter.sol` | Interfaz `execute(data, prev) → out`. |
| `src/adapters/SwapAdapter.sol` | Swap en un AMM. `amountIn` puede ser un valor fijo, `USE_PREV` (la salida del paso anterior) o `USE_BALANCE` (todo el saldo). |
| `src/adapters/AssertBalanceAdapter.sol` | Guarda: revierte si el saldo de un token queda por debajo de un mínimo. |
| `src/adapters/CallAdapter.sol` | Llamada arbitraria con un *approve* temporal que se resetea a 0 al terminar. |
| `src/mocks/*` | `FlashLender` (ERC-3156 con fee), `SimpleAMM` (x·y=k, 0,3 %), `MockERC20` y `EvilAdapter` (solo para la demo de ataque). |
| `script/ArbRecipe.s.sol` | Busca el tamaño óptimo del arbitraje y lo ejecuta. |

## Diseño

- **Adapters por `delegatecall`:** el código del adapter corre en el contexto del executor,
  así que los tokens y los approvals son del executor y no hay que transferir fondos entre
  contratos. Los adapters **no tienen estado**: todo viaja en `data`.
- **Encadenamiento:** cada paso devuelve un `uint256` que entra como `prev` en el siguiente.
  Así se arma "comprá WETH con X USDC y vendé **lo que hayas recibido**" sin saber de
  antemano la cantidad.
- **Flujo de `run`:**
  1. Toma el saldo previo y marca `_executing = true`.
  2. Llama a `lender.flashLoan`.
  3. El lender llama a `onFlashLoan`, que ejecuta los pasos y aprueba `amount + fee`.
  4. El lender cobra.
  5. `_settle` calcula `ganancia = saldo final − saldo previo` y exige `≥ minProfit`.
  6. Transfiere la ganancia al owner.
- **Revert con contexto:** si un paso falla, se revierte con `StepFailed(índice, motivo)`, así
  se sabe qué paso y por qué.
- `runWithoutLoan` ejecuta la misma receta con capital propio, por ejemplo para rebalancear.

## Incentivos

El owner solo paga gas si la receta revierte, porque nada queda a medias. El lender cobra el
fee (9 bps en los tests). El `minProfit` funciona como protección de slippage *global* de toda
la receta: si un bot de MEV se adelanta y mueve el precio, la transacción revierte.

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Llamar a `onFlashLoan` directamente con datos falsos | `isLender[msg.sender]` | `test_CallbackGuards` |
| Pedir un flash loan *a nombre* del executor desde otro contrato (initiator ajeno) para que ejecute una receta maliciosa | `initiator == address(this)` | `test_CallbackGuards` |
| Lender confiable que llama al callback fuera de `run` | flag `_executing` (`NotExecuting`) | `test_CallbackGuards` |
| Lender no confiable | whitelist en `run` | `test_UntrustedLenderRejected` |
| Adapter arbitrario | whitelist `isAdapter` | `test_AdapterNotWhitelisted` |
| **Adapter malicioso aprobado por error** | No hay defensa técnica: un `delegatecall` puede escribir **cualquier** slot, incluido `_owner`. Hay que auditar cada adapter. | `test_EvilAdapterShowsWhyWhitelistMatters` |
| Approvals colgados que después se usan para drenar | `CallAdapter` resetea el approve a 0 | `test_RunWithoutLoanUsingCallAdapter` |
| Sandwich o slippage | `minProfit` + `minOut` por paso | `test_InsufficientProfitReverts` |
| Receta perdedora | No alcanza para repagar, así que revierte todo | `test_ReverseArbLosesAndReverts` |
| Reentrada (un paso que vuelve a llamar a `run`) | flag `_executing` → `Reentrant` | — |

El fuzz `testFuzz_ArbNeverLeavesDust` verifica que, para cualquier tamaño, el executor
termina sin saldo: o el owner cobra la ganancia o la transacción revierte.

## Script

```bash
forge script script/ArbRecipe.s.sol -vv
# Monto optimo USDC: 5000 ganancia esperada: 203
# Ganancia real USDC: 203
```

El script cotiza con `getAmountOut` (solo vistas), elige el monto óptimo y ejecuta la receta.

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
