# 06 · TWAP Oracle sobre el AMM propio

**Nivel:** Intermedio-Avanzado

Oráculos de **precio promedio ponderado en el tiempo (TWAP)** construidos sobre los
acumuladores `price0CumulativeLast` y `price1CumulativeLast` del AMM x·y=k del proyecto 01.
Ese AMM está copiado en `src/amm/` para que el proyecto sea independiente.

## Contratos

| Archivo | Rol |
|---|---|
| `src/amm/CPAMMPair.sol`, `CPAMMFactory.sol` | AMM con acumuladores UQ112x112·segundo (copia del proyecto 01). |
| `src/libraries/OracleLibrary.sol` | Acumuladores **contrafactuales** al bloque actual y conversión a monto. |
| `src/SimpleTWAPOracle.sol` | Ventana **fija** para un par: `update()` cada `PERIOD` y `consult()`, que revierte si el precio está viejo (`MAX_AGE`). |
| `src/SlidingWindowOracle.sol` | Ventana **deslizante** para cualquier par de la fábrica: buffer circular de `granularity` observaciones. |

## Diseño

- El par acumula `precio × segundos transcurridos` con las reservas **anteriores** a cada
  operación, en el primer update de cada bloque. Así:
  - `TWAP = (acum_fin − acum_inicio) / Δt`;
  - las restas son `unchecked` porque los acumuladores pueden desbordar a propósito
    (aritmética modular) y la diferencia sigue siendo correcta.
- `OracleLibrary.currentCumulativePrices` agrega el tramo desde el último update del par
  sin escribir en él, como si se hubiera llamado a `sync()`.
- En la ventana deslizante, el slot es `(timestamp / periodSize) % granularity`. La
  consulta promedia desde la observación más vieja de la ventana hasta ahora.
- La consulta **revierte** si falta historia o si el keeper dejó de actualizar. Es preferible
  fallar a entregar un precio sobre una ventana incorrecta.

## Incentivos económicos

Manipular el TWAP exige **sostener** un precio falso durante una fracción grande de la
ventana. Mientras tanto, cualquier arbitrajista puede devolver el precio a su valor real y
ganar la diferencia, así que el atacante pierde dinero de forma continua. El costo crece
con la liquidez del pool y con la duración de la ventana.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Flash loan para mover el spot y leer el precio en el mismo bloque | El acumulador usa reservas previas: el TWAP **no cambia** en el mismo bloque (tests y fuzz). |
| Sostener la manipulación durante un período | El efecto es proporcional al tiempo (≈1/6 de la ventana → ≈1/6 del desvío), con pérdida por arbitraje. |
| Keeper caído (precio viejo) | `MAX_AGE` en el oráculo simple y `MissingHistoricalObservation` en el deslizante. |
| Overflow de acumuladores o timestamps de 32 bits | Aritmética modular `unchecked` en las restas. |
| Token que no pertenece al par | `InvalidToken` / `PairNotFound`. |

## Limitaciones

- El TWAP es **aritmético**: el promedio del precio de A no es el inverso del promedio del
  precio de B. El test lo muestra (0,625 contra 2,5). Uniswap V3 usa un promedio geométrico
  (ticks) para evitarlo.
- En pools chicos la manipulación sostenida es barata. Hay que dimensionar la ventana según
  la liquidez.
- En Proof of Stake, un validador que produce varios bloques seguidos puede manipular sin
  exponerse al arbitraje (manipulación *multi-block*).

## Tests

9 tests (1 de fuzz). Cubren:
- precio estable;
- falta de historia y keeper caído;
- manipulación en el mismo bloque, que no mueve el TWAP;
- manipulación sostenida, con efecto proporcional;
- oráculo simple: promedio, precio viejo y token inválido.

> Nota técnica: con `via_ir`, en los tests usamos `vm.getBlockTimestamp()` en lugar de
> `block.timestamp` después de `vm.warp`. El compilador puede volver a leer el opcode
> TIMESTAMP en otro momento.


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
