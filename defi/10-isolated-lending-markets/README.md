# 10 · Isolated Lending Markets (estilo Silo / Morpho Blue)

**Nivel:** Avanzado

Protocolo singleton de **mercados de préstamo aislados y sin permiso**. Cada mercado es una
tupla `(loanToken, collateralToken, oracle, irm, lltv)` identificada por su hash. El riesgo
de un mercado **no contagia** a los demás: la deuda incobrable de un colateral que colapsa
la absorben solo los prestamistas de ese mercado.

## Contratos

| Archivo | Rol |
|---|---|
| `src/IsolatedLending.sol` | Núcleo: `createMarket`, `supply`/`withdraw`, `supplyCollateral`/`withdrawCollateral`, `borrow`/`repay`, `liquidate`, `accrueInterest`. |
| `src/Interfaces.sol` | `IOracle` (precio ×1e36) e `IIrm` (tasa por segundo). |
| `src/LinearIrm.sol` | Tasa lineal `base + slope·U`. |
| `src/mocks/MockOracle.sol` | Oráculo configurable para los tests. |

## Diseño

- **Sin permiso:** cualquiera crea un mercado con un IRM y un LLTV habilitados por el owner.
  El oráculo lo elige el creador, y cada prestamista decide si confía en él.
- **Shares con desplazamiento virtual** (`+1e6` shares y `+1` activo): neutraliza el ataque
  de inflación y el robo por redondeo en mercados vacíos.
- **Interés compuesto** aproximado con Taylor (`x + x²/2 + x³/6`). Todo el interés va a
  los prestamistas.
- **Contabilidad por mercado:** `totalSupplyAssets` y `totalBorrowAssets` son propios de
  cada mercado, y `withdraw` y `borrow` verifican la liquidez del mercado, no el balance
  global del contrato.
- **Liquidación:**
  - el liquidador elige cuánto colateral tomar y repaga `seized × precio / LIF`;
  - `LIF = min(1,15, 1/(1 − 0,3·(1 − LLTV)))`: con un LLTV más bajo, el incentivo es mayor;
  - si el deudor queda sin colateral, la deuda remanente se **socializa dentro del mercado**,
    reduciendo `totalSupplyAssets`.

## Incentivos económicos

- Los prestamistas eligen su riesgo: un mercado WETH con LLTV del 86 % paga menos que uno
  de MEME con LLTV del 50 %, pero es mucho más seguro.
- Los creadores de mercados no necesitan gobernanza para listar activos nuevos.
- El LIF compensa a los liquidadores. Al estar acotado, el deudor no pierde de más.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Colateral basura que contamina todo el protocolo (caso Venus/XVS, Cream) | Aislamiento: la deuda incobrable solo afecta al mercado (test `IsolationBadDebtStaysInMarket`). |
| Usar la liquidez de otro mercado | Chequeo `totalBorrow ≤ totalSupply` por mercado (`CannotBorrowOtherMarketsLiquidity`). |
| Inflación de shares o donación | Shares virtuales y contabilidad interna (no se usa `balanceOf`). |
| Redondeo a favor del usuario | Supply y withdraw redondean hacia abajo; borrow y repay hacia arriba (fuzz de no-ganancia). |
| Oráculo malicioso elegido por el creador | Está fuera del protocolo: cada prestamista elige en qué mercados confiar. Riesgo documentado. |
| Liquidar posiciones sanas | `Healthy`. |
| Reentrancia | `nonReentrant` y efectos aplicados antes de las transferencias. |

## Limitaciones

- No hay fee de protocolo, callbacks ni flash loans (ver el proyecto 15).
- `uint128` para los totales: suficiente para tokens normales.

## Tests

12 tests (2 de fuzz). Cubren:
- creación sin permiso con parámetros habilitados;
- LLTV;
- intereses compuestos;
- liquidación con LIF y contra posiciones sanas;
- **aislamiento de la deuda incobrable**;
- liquidez por mercado y utilización;
- repago y retiro de colateral;
- inflación de shares;
- fuzz de no-ganancia.


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
