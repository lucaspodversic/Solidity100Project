# 68 · Préstamos sobre-colateralizados con liquidaciones y flash loans — Avanzado

Un mercado estilo Aave/Compound simplificado: un activo prestable (DAI) contra un colateral (WETH).

| Ruta | Qué hay |
|---|---|
| `src/LendingPool.sol` | Depósitos con shares, préstamos, curva de tasas con kink, reservas, liquidaciones y flash loans ERC-3156. |
| `src/LiquidationBot.sol` | Bot que liquida **sin capital propio**: flash loan → liquidar → vender → devolver. |
| `src/Mocks.sol` | Tokens, oráculo y un DEX de precio fijo. |
| `test/LendingPool.t.sol` | 15 tests, incluido un fuzz de solvencia. |

## Parámetros

| | |
|---|---|
| LTV (máximo para pedir prestado) | 75% |
| Umbral de liquidación | 80%. HF = colateral × 0,8 / deuda |
| Bonus de liquidación | 5% |
| Close factor | 50% |
| Reserve factor | 10% del interés |
| Flash fee | 0,09% (redondeo hacia arriba), va a los prestamistas |
| Curva de tasas | 2% + 10%·U/0,8 hasta el kink (80%); después +100% en el tramo final |

## Incentivos

- **Prestamistas**: ganan el interés (90%) más las fees de flash loans, a través del precio creciente de sus shares.
- **Prestatarios**: obtienen liquidez sin vender su WETH.
- **Liquidadores**: el bonus del 5% paga gas y riesgo. Con flash loans **no necesitan capital** (ver `test_LiquidationBotWithFlashLoan`), lo que vuelve las liquidaciones más competitivas y el protocolo más solvente.
- **Curva con kink**: por encima del 80% de utilización la tasa se dispara. Eso atrae depósitos y empuja repagos, para que nunca falte liquidez para retirar.

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Flash loan para manipular el precio de las shares | La contabilidad usa `cash` interno, no `balanceOf` | `test_DonationDoesNotInflate` |
| Depositar o pedir prestado con fondos del flash loan | `noFlash` en deposit, withdraw, borrow y removeCollateral | `test_RevertWhen_DepositDuringFlash` |
| No devolver el flash loan | El cobro es explícito con `transferFrom(amount+fee)` | `test_RevertWhen_FlashLoanNotRepaid` |
| Inflación del primer depositante | Shares virtuales (+1e3 / +1) | `test_InflationAttackMitigated` |
| Retirar colateral quedando insolvente | Chequeo de LTV | `test_RevertWhen_RemoveCollateralUnhealthy` |
| Liquidar posiciones sanas o sobre-liquidar | `Healthy`, `TooMuchRepay` | 2 tests |
| Callback del bot invocado por terceros | El bot exige `msg.sender == pool && initiator == this` | (bot) |
| Reentrada | `nonReentrant` más CEI | |
| Redondeos | Siempre a favor del pool: deuda hacia arriba, seize y withdraw hacia abajo | |

## Limitaciones

- Un solo par de activos. El oráculo es un mock; en producción usar Chainlink con chequeos de staleness (ver el proyecto 67).
- Interés simple dentro de cada intervalo, compuesto entre llamadas a `accrue`.
- Sin manejo de bad debt (si cae el colateral más rápido de lo que se liquida). Ver la solución en el proyecto 67.
