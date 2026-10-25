# 12 · Liquidation Bot (contrato + script)

**Nivel:** Avanzado

Bot de liquidación **con capital cero**. En una sola transacción toma un flash loan, liquida
una posición insolvente del LendingPool del proyecto 09, vende el colateral incautado en un
DEX, devuelve el préstamo y se queda con la diferencia. Si la ganancia no alcanza el mínimo,
revierte todo.

## Contratos

| Archivo | Rol |
|---|---|
| `src/LiquidationBot.sol` | `execute(Params)`, que hace flash loan → liquidate → swap → repago, y `scan(users)`, una vista que estima HF, repago, colateral y ganancia. |
| `src/protocol/*` | Copia del LendingPool, JumpRateModel y PriceOracle del proyecto 09. |
| `src/mocks/FlashLender.sol` | Prestamista ERC-3156 con fee de 0,09 % (simula Aave o Balancer). |
| `src/mocks/OracleDex.sol` | DEX que cotiza al precio del oráculo menos fee y slippage configurables. |
| `src/mocks/Borrower.sol` | Cuentas auxiliares que usa el script. |
| `script/RunBot.s.sol` | Simulación del loop de un keeper: abre 4 posiciones, baja el precio, escanea y liquida las rentables. |

## Diseño

```
keeper off-chain ──scan()──► oportunidades (estProfit)
       │
       └─execute()──► FlashLender.flashLoan(USDC)
                        └─► onFlashLoan:
                              pool.liquidate(USDC, WETH, user, repay)  → recibe WETH + 5 %
                              dex.swap(WETH→USDC, minOut = préstamo + fee)
                              approve(lender, préstamo + fee)
                     ◄─ ganancia ≥ minProfit, o revert
```

Ejemplo (test y script): ETH baja de 2000 a 1800, Alice debe 15 000 USDC con 10 ETH (HF 0,96).
- Repago: 7500 USDC.
- Colateral incautado: 4,375 ETH (7875 USD).
- Venta: 7851 USDC después del fee del DEX.
- Costo: 7506,75 USDC (7500 de préstamo + 6,75 de fee del flash loan).
- **Ganancia: 344,6 USDC**, sin capital propio.

## Incentivos económicos

- El bonus de liquidación (5 %) paga el riesgo y el gas del liquidador. El bot liquida solo
  si `bonus > fee del DEX + slippage + fee del flash loan + gas`.
- La competencia entre bots (MEV) trae la ganancia hacia cero. En la vida real se pujan
  priority fees o se usan bundles privados (Flashbots) para no ser front-runeado.
- `minProfit` protege contra cambios de estado entre `scan` y `execute`: si la ganancia
  cambió, la transacción revierte y solo se pierde gas.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Llamar a `onFlashLoan` directamente | `msg.sender == lender`, si no `UntrustedLender`. |
| Pedir un flash loan al lender real con el bot como receptor | `initiator == address(this)`, si no `UntrustedInitiator`. |
| Robar fondos con approvals que quedaron del bot | Approvals exactos y puestos en 0 después de liquidar. |
| Sandwich o slippage en el swap | `minOut` = monto necesario para repagar, más `minProfit` global. Si no se cumplen, revierte (test `RevertsWhenDexSlippageEatsBonus`). |
| Un tercero usa el bot para hacerle pagar fees | `execute` es `onlyOwner`. |
| Reentrancia | `nonReentrant` en `execute`. |
| Fondos atrapados | `sweep` (solo el owner). |

## Limitaciones

- El DEX está simulado al precio del oráculo. En producción hay que usar Uniswap o 1inch
  y calcular el impacto de precio real.
- `scan` usa índices del último accrue, así que es una aproximación. `execute` es exacto.
- El keeper off-chain (mempool, gas bidding) está representado por el script, no
  implementado como servicio.

## Tests

11 tests (1 de fuzz):
- scan;
- ganancia con capital cero;
- concordancia entre scan y ejecución;
- minProfit;
- slippage;
- posición sana;
- onlyOwner;
- callbacks ajenos;
- múltiples liquidaciones;
- sweep;
- fuzz "nunca pierde".

```bash
forge script script/RunBot.s.sol -vv   # loop del keeper simulado
```


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
