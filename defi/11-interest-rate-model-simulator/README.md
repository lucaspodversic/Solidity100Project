# 11 · Interest Rate Model Simulator

**Nivel:** Intermedio

Simulador **on-chain** de modelos de tasa de interés para protocolos de préstamo. Compara
la tasa lineal, la de kink (Compound/Aave) y la adaptativa (Morpho AdaptiveCurve) sobre
escenarios de utilización a lo largo del tiempo.

## Contratos

| Archivo | Rol |
|---|---|
| `src/IInterestRateModel.sol` | Interfaz común: `borrowRate(U)`, `update(U, dt)` y `name()`. |
| `src/models/LinearModel.sol` | `r = base + slope·U`. |
| `src/models/KinkModel.sol` | Dos pendientes con kink en `U*`. |
| `src/models/AdaptiveCurveModel.sol` | Curva fija alrededor de `U*`, con un `rateAtTarget` que se adapta en el tiempo. |
| `src/RateSimulator.sol` | `curve`, `simulate`, `compare` y `rampScenario`. Calcula índices, interés pagado y ganado, y APR promedio y máximo. |
| `script/CompareModels.s.sol` | Imprime la tabla de curvas y un escenario de estrés. |

## Diseño

- Tasas **anuales en WAD**. El simulador compone por paso: `index *= 1 + r·dt/año`.
  Con pasos diarios el resultado se aproxima a la composición continua (el test lo verifica
  contra `e^0,12`).
- Tasa de depósito: `r_borrow · U · (1 − reserveFactor)`.
- **Modelo adaptativo:**
  - error normalizado `err ∈ [−1, 1]`;
  - curva `×4` en U = 100 % y `×1/4` en U = 0;
  - `rateAtTarget ← rateAtTarget·(1 + speed·err·dt)`, acotado a [0,1 %, 200 %].
- Los modelos con estado se actualizan en cada paso. Por eso `simulate` no es `view`:
  conviene usarlo como `eth_call` o desde un script.

## Incentivos económicos

- **Lineal:** en estrés no sube lo suficiente (22 % con U = 100 %), así que nadie tiene
  incentivo a repagar y los depositantes no pueden retirar.
- **Kink:** la pendiente fuerte sobre U* (79 % con U = 100 %) obliga a los deudores a repagar
  y atrae depositantes. Requiere que la gobernanza calibre bien los parámetros.
- **Adaptativo:**
  - reacciona al instante con la curva;
  - si el desequilibrio persiste, sigue moviendo la tasa hasta llevar U al objetivo, sin
    gobernanza;
  - contra: es manipulable por alguien que mantenga U artificialmente alto o bajo durante
    mucho tiempo, aunque eso tiene un costo.

Salida de ejemplo del script (bps):

```
U(%)  | Lineal | Kink | Adaptive
50    | 1200   | 250  | 266
90    | 2000   | 4150 | 400
100   | 2200   | 7900 | 1600
```

## Ataques y defensas

| Riesgo | Mitigación |
|---|---|
| Corrida bancaria con U = 100 % | El kink y el adaptativo suben fuerte la tasa (test `CompareStressScenario`). |
| Manipulación del modelo adaptativo | Límites MIN/MAX y cambio máximo por intervalo de −50 % / +100 %. |
| Overflow o underflow en el error firmado | `int256` con U acotado a [0, 1]. |
| Tasa de depósito mayor que la de préstamo (insolvencia) | Fuzz `SupplyLeBorrow`. |
| Curva no monótona (incentivos invertidos) | Fuzz `Monotonic` para los tres modelos. |

## Limitaciones

- El modelo adaptativo usa una aproximación lineal por paso en lugar de `exp()`.
- El simulador supone una U exógena por paso: no modela la reacción de los usuarios a la tasa.

## Tests

12 tests (2 de fuzz):
- forma de cada curva;
- adaptación hacia arriba y hacia abajo, y sus límites;
- composición contra el valor analítico;
- reserve factor;
- comparación bajo estrés;
- monotonía y `supply ≤ borrow`.

```bash
forge script script/CompareModels.s.sol   # tabla comparativa
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
