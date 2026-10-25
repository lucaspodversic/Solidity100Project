# 14 · Health Factor Dashboard (vista on-chain + script)

**Nivel:** Intermedio

**Lens** on-chain de solo lectura que arma, en una sola `eth_call`, todo lo que necesita un
panel de riesgo de un protocolo de préstamos (el LendingPool del proyecto 09). Incluye un
script de Foundry que imprime el dashboard en la consola.

## Contratos

| Archivo | Rol |
|---|---|
| `src/HealthFactorLens.sol` | Ver la tabla de funciones abajo. |
| `src/protocol/*` | Copia del LendingPool del proyecto 09. |
| `src/mocks/Account_.sol` | Cuenta auxiliar del script. |
| `script/Dashboard.s.sol` | Imprime el dashboard. Tiene un modo demo y un modo real contra un lens desplegado. |

Funciones de `HealthFactorLens.sol`:

| Función | Qué devuelve |
|---|---|
| `dashboard(user)` | Desglose por activo, totales, HF, disponible para pedir, LTV usado y categoría de riesgo. |
| `liquidationPrice(user, asset)` | Precio del colateral al que HF = 1. |
| `stressTest(user, asset, drops)` | HF ante caídas porcentuales del precio. |
| `hfAtPrice(user, asset, price)` | HF con un precio hipotético. |
| `maxBorrow` / `maxWithdraw` | Montos exactos sin quedar insolvente. |
| `batch(users)` | HF y riesgo de muchas cuentas, para alertas. |

## Diseño

- **Sin estado ni permisos:** solo lee el pool, así que cualquiera puede desplegarlo o
  usarlo, y no agrega superficie de ataque.
- **Precio de liquidación:** se despeja `Σ otros·lt + q·P*·lt = deuda`, de donde
  `P* = (deuda − otros) / (q·lt)`.
  - Devuelve 0 si los demás colaterales ya cubren la deuda.
  - Devuelve `max` si es imposible salvar la posición con ese activo.
- **What-if:** `hfAtPrice` recalcula con el precio sustituido en los dos lados, colateral y
  deuda. El fuzz verifica que coincide **exactamente** con el HF del pool después de cambiar
  el oráculo.
- **Categorías de riesgo:** NoDebt, Safe (≥ 1,5), Warning (≥ 1,1), Danger (≥ 1) y
  Liquidatable (< 1).

Salida del script (demo):

```
Colateral USD: 20000   Deuda USD: 12000   Disponible: 3000
Health factor (x1000): 1333   Riesgo: Atencion
Precio de liquidacion (USD): 1500
caida 10 % → HF 1.200 | 20 % → 1.066 | 30 % → 0.933 | 40 % → 0.800
```

Contra una red real (solo lectura):

```bash
HF_LENS=0xLens HF_USER=0xCuenta forge script script/Dashboard.s.sol --rpc-url $RPC_URL
```

## Incentivos económicos

- Los usuarios ven cuánto margen tienen y a qué precio los liquidan, así que reaccionan antes
  agregando colateral o repagando. Eso baja el volumen de liquidaciones con descuento.
- Los keepers usan `batch` para encontrar rápido cuentas liquidables (ver el proyecto 12).

## Ataques y riesgos

| Riesgo | Mitigación |
|---|---|
| Datos desactualizados (índices del último accrue) | Está documentado. El error es de segundos o minutos de interés. Para un valor exacto, hacer `accrue` antes. |
| Gas ilimitado en `batch` con listas enormes | Solo se usa vía `eth_call` (sin costo). Conviene paginar del lado del cliente. |
| Usar el lens desde otro contrato para tomar decisiones | Está pensado para off-chain. Si se lo usa on-chain, se heredan los riesgos del oráculo del pool. |
| Precio de liquidación engañoso con deuda en el mismo activo | La limitación está documentada: supone que no hay deuda en `collAsset`. |

## Tests

12 tests (1 de fuzz):
- totales y coherencia con el pool;
- categorías de riesgo;
- precio de liquidación con uno y con varios colaterales, y casos borde;
- stress test;
- `hfAtPrice` contra un cambio real de precio;
- maxBorrow y maxWithdraw exactos;
- batch.

```bash
forge script script/Dashboard.s.sol -vv
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
