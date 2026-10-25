# 07 · Impermanent Loss Calculator

**Nivel:** Intermedio

Calculadora on-chain de **pérdida impermanente (IL)** para pools x·y=k de rango completo y
para posiciones de **liquidez concentrada** estilo Uniswap V3. También calcula la
comisión y el APR necesarios para empatar con HODL, y permite registrar posiciones para
pedir reportes más adelante.

## Contratos

| Archivo | Rol |
|---|---|
| `src/libraries/ILMath.sol` | Librería pura en punto fijo WAD: `ilConstantProduct`, `lpValueCP`, `hodlValue`, `amountsPerLiquidity`, `ilConcentrated`, `breakevenFees` y `breakevenApr`. |
| `src/ILCalculator.sol` | Wrapper consultable (`ilFullRange`, `ilRange`, `scenarios`) más un registro de posiciones (`record`, `report`). |
| `script/ILTable.s.sol` | Imprime una tabla comparativa de IL entre rango completo y concentrado. |

## Diseño

- **Rango completo:** `IL = 1 − 2√r/(1+r)`, con `r = P1/P0`. Por la desigualdad AM-GM
  vale siempre ≥ 0 y es simétrica en `r` y `1/r`.
- **Valor LP en x·y=k:** `2·L·√P1`, con `L = √(x0·y0)`.
- **Concentrada en [pa, pb]:** tokens por unidad de liquidez, igual que en Uniswap V3:
  - si `p ≤ pa`, todo está en X: `x = 1/√pa − 1/√pb`;
  - si `p ≥ pb`, todo está en Y: `y = √pb − √pa`;
  - si está dentro del rango, `x = 1/√p − 1/√pb` e `y = √p − √pa`.

  El IL se calcula comparando ese valor contra HODL.
- **Breakeven:** `fees = HODL − LP`. El APR es `fees/HODL · 365/días`.

Salida del script (precio inicial 2000, rango [1600, 2500]):

```
precio | IL full (bps) | IL rango (bps)
  500      2000          5763
 1000       571          2939
 1600        61           586
 2000         0             0
 2400        41           392
 4000       571          2939
 8000      2000          5763
```

## Incentivos económicos

El IL es el costo de que los arbitrajistas reequilibren el pool contra el LP: el pool
siempre vende el activo que sube y compra el que baja. Las comisiones tienen que compensarlo.
La liquidez concentrada cobra más comisiones por unidad de capital, pero **amplifica el IL**
(≈10x en el ejemplo). La calculadora sirve para decidir el rango y para estimar el APR de
comisiones mínimo que se necesita.

## Ataques y consideraciones de seguridad

| Riesgo | Mitigación |
|---|---|
| Overflow en `x0·y0` o `p·1e18` | Rangos razonables (hasta 1e24 en el fuzz) y `Math.mulDiv` en los productos intermedios. |
| Rangos inválidos (`pa ≥ pb`, precio 0) | Errores `BadRange` y `ZeroPrice`. |
| Precio de entrada manipulado | El contrato **no custodia fondos** y es solo informativo. Para automatizar, el precio debería salir de un TWAP (proyecto 06), nunca del spot. |
| Redondeo | `Math.sqrt` trunca; las pruebas usan tolerancias de 1e-9 a 1e-12. |

## Tests

12 tests (2 de fuzz). Cubren:
- valores conocidos de IL: 5,72 % y 20 %;
- simetría entre `r` y `1/r`;
- que la LP nunca supere a HODL (AM-GM);
- que la liquidez concentrada amplifica el IL;
- rangos fuera de precio y la convergencia de un rango amplio a rango completo;
- registro, reporte y APR de breakeven.

Para ver la tabla: `forge script script/ILTable.s.sol -vv`.


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
