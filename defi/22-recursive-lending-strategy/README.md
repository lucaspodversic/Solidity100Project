# 22 · Recursive Lending Strategy (looping LST/WETH)

**Nivel:** Avanzado

Esta estrategia de **staking apalancado** pone un LST (staked ETH líquido) como colateral, pide
WETH prestado, compra más LST con ese WETH y lo vuelve a depositar, repitiendo hasta llegar al
apalancamiento objetivo.

```
APY_capital ≈ L · yield_LST − (L − 1) · tasa_WETH
```

En el test `test_LeverageAmplifiesYield`, con el LST al 4 % y una tasa de WETH menor al 1 %, el
capital rinde **≈14,3 %** a 4x. Sin apalancar rendiría 4 %.

## Componentes

| Archivo | Rol |
|---|---|
| `src/RecursiveLendingStrategy.sol` | La estrategia. Es `Ownable`, así que la opera su dueño (una persona o un vault). |
| `src/protocol/*` | Pool de lending del proyecto 09, copiado: `LendingPool`, `JumpRateModel`, `PriceOracle`. |
| `src/mocks/OracleDex.sol` | DEX que cotiza al precio del oráculo con 0,3 % de fee. |
| `src/mocks/FlashLender.sol` | Prestamista ERC-3156 con fee del 0,05 %. |

## Operaciones

| Función | Qué hace |
|---|---|
| `deposit(lst)` | Aporta capital propio. |
| `leverageLoop(target, maxIter)` | Versión **iterativa**. En cada vuelta pide prestado hasta el 95 % del poder de préstamo restante, o lo que falte para el objetivo; compra LST y lo deposita. No necesita flash loan, pero gasta mucho gas: a 5x consume ≈784k. |
| `leverageFlash(target)` | Versión **con flash loan**. Pide de golpe `(L−1)·capital` en WETH, compra el LST, lo deposita y toma prestado del pool `flash + fee` para devolverlo. A 5x consume ≈354k de gas. |
| `deleverageStep(lst)` | Desapalanca parcialmente sin flash: retira LST, lo vende y repaga deuda. |
| `unwind()` | Cierra todo. Pide en flash el total de la deuda, la repaga, retira todo el LST, vende solo lo necesario para devolver el flash y le transfiere el resto al owner. |
| `position()` / `leverage()` / `healthFactor()` / `liquidationRatio()` | Vistas de riesgo. `liquidationRatio = D / (C·lt)` es el precio LST/WETH al que la posición se vuelve liquidable. |

## Riesgos e incentivos

- **Riesgo de precio de ETH: casi nulo.** Colateral y deuda son ETH, así que se mueven juntos.
- **Riesgo de depeg del LST.** Es el riesgo real. A 4x la posición se liquida si el LST cae
  aproximadamente un 19,4 % frente a WETH (`test_LiquidationRatioAndDepeg`). Cuanto más
  apalancamiento, menor el margen: a 8x, `D/C = 0,875` y el precio de liquidación queda en 0,94.
- **Riesgo de tasa.** Si la utilización de WETH sube, por ejemplo porque todos hacen looping,
  la tasa salta por encima del kink del `JumpRateModel` y el carry se vuelve negativo. El
  protocolo de lending usa esa curva justamente para desincentivar el looping excesivo.
- **Costos.** Cada vuelta paga fee de swap y la versión flash suma la fee del flash loan. Por
  eso el apalancamiento final es levemente menor al teórico y el capital pierde ≈1 % al entrar.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| **Swap sandwicheado** o DEX manipulado. | Cada swap usa `minOut = precio_oráculo · (1 − maxSlippageBps)`. El owner configura el slippage, con un tope del 5 %. |
| **Callback falso:** alguien llama a `onFlashLoan` o inicia un flash loan apuntando a la estrategia. | Se exige `msg.sender == lender`, `initiator == this`, `token == WETH` y que la bandera `_inFlash` esté activa. |
| **Sobre-apalancamiento.** | `MAX_LEVERAGE = 8x` y `healthFactor ≥ minHealthFactor` (1,05 por defecto, configurable desde 1,01) después de cada operación. Si no se cumple, revierte con `HealthTooLow`. |
| **Uso por terceros.** | Todo lo que mueve fondos es `onlyOwner`. |
| **Oráculo viejo o manipulado.** | Depende de `PriceOracle`, que rechaza precios con más de `maxAge` de antigüedad. En producción haría falta un oráculo de tipo de cambio del LST, no un precio de mercado. |

### Limitaciones

- El rendimiento del LST se simula subiendo su precio en el oráculo, igual que en wstETH, que
  acumula valor por tipo de cambio.
- Antes de un depeg no hay rebalanceo automático. Un keeper debería llamar a `deleverageStep`
  cuando el HF baje de cierto umbral (ver el proyecto 16, Position Manager).

## Tests (`test/RecursiveLendingStrategy.t.sol`, 14)

Cubren:
- posición inicial;
- loop que alcanza el objetivo y loop cortado por `maxIter`;
- versión flash en un solo paso, con la comparación de gas;
- límites de apalancamiento y de HF;
- amplificación del rendimiento;
- ratio de liquidación y depeg con liquidación real;
- `deleverageStep` y `unwind` (con y sin deuda);
- autenticación del callback y `onlyOwner`;
- fuzz de objetivos entre 1,2x y 7x.

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
