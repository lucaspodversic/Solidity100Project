# 09 · Simple Lending (depósitos, préstamos, intereses y liquidaciones)

**Nivel:** Avanzado

Protocolo de préstamos **multi-activo con pool compartido** (estilo Aave v2 / Compound):

- los depósitos ganan interés y funcionan como colateral;
- los préstamos pagan una tasa variable según la utilización;
- las posiciones con health factor < 1 se liquidan con un bonus para el liquidador.

## Contratos

| Archivo | Rol |
|---|---|
| `src/LendingPool.sol` | Núcleo: `deposit`, `withdraw`, `borrow`, `repay`, `liquidate`, `accrue`, `accountData`, `healthFactor`, `marketRates`. |
| `src/JumpRateModel.sol` | Tasa con *kink*: `base + slope1·U/U*`, y por encima de U*, `+ slope2·(U−U*)/(1−U*)`. |
| `src/PriceOracle.sol` | Oráculo administrado con antigüedad máxima (`StalePrice`). |

## Diseño

- **Índices RAY (1e27):**
  - el usuario guarda saldos escalados y su saldo real es `escalado × índice`;
  - acumular intereses solo cambia `supplyIndex` y `borrowIndex`, con costo O(1).
- **Reparto del interés:**
  - `interés = deuda × tasa × Δt`;
  - los depositantes cobran `interés × (1 − reserveFactor)` a través de `supplyIndex`;
  - la tesorería recibe la reserva como saldo de depósito.
- **Riesgo por activo:**
  - `LTV < liquidationThreshold`, lo que deja un colchón entre el límite de préstamo y la
    liquidación;
  - se exige `threshold × (1 + bonus) < 1`.
- **Health factor:** `HF = Σ colateral × umbral / Σ deuda`.
- **Liquidación:**
  - close factor del 50 %;
  - el colateral entregado es `repago × pDeuda/pColateral × (1 + bonus)`;
  - si el colateral no alcanza, el repago se ajusta en proporción.
- **`cash` contable:** el contrato no usa `balanceOf`. Las donaciones no alteran la
  utilización ni los saldos.

## Incentivos económicos

| Actor | Incentivo |
|---|---|
| Depositante | Interés `r_borrow × U × (1 − rf)`. |
| Deudor | Liquidez sin vender su colateral (por ejemplo, apalancarse o cubrir gastos). |
| Liquidador | Bonus del 5 %: compensa el gas y el riesgo de precio, y mantiene sano al protocolo. |
| Protocolo | Reserva del 10 % del interés, que funciona como colchón ante deuda incobrable. |
| Kink | Por encima del 80 % de utilización la tasa se dispara: atrae depósitos, fuerza repagos y garantiza liquidez para retiros. |

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Retirar colateral dejando deuda impaga | Chequeo de HF **después** de actualizar el estado en `withdraw` y `borrow`. |
| Reentrancia (tokens con hooks) | `nonReentrant` en todas las operaciones de usuario. |
| Donación para manipular la utilización o el tipo de cambio | `cash` contable (test `DonationDoesNotChangeAccounting`). |
| Precio viejo o inexistente | `PriceOracle.maxAge`: las operaciones que dependen de precios revierten. |
| Liquidar posiciones sanas o liquidar todo de golpe | `HealthyPosition` y close factor del 50 %. |
| Parámetros que hagan el bonus insolvente | Validaciones en `listMarket`. |
| Redondeo explotable (depositar 1 wei y retirar 2) | Redondeo siempre a favor del protocolo (fuzz `NoFreeMoney`). |
| Insolvencia por intereses | Fuzz `Solvency`: `cash + deuda ≥ depósitos` hasta 5 años después. |

## Limitaciones

- No hay socialización de **deuda incobrable**: si el colateral llega a cero con deuda
  pendiente, la pérdida queda implícita en el pool.
- El oráculo es administrado. En producción hacen falta Chainlink y un TWAP, además de
  circuit breakers.
- No hay caps de depósito ni de préstamo, ni modo aislado (ver el proyecto 10).
- `_accrueAll` recorre todos los mercados: está pensado para unas pocas decenas de activos.

## Tests

15 tests (2 de fuzz). Cubren:
- LTV y su límite;
- intereses y su reparto 90/10;
- repago total;
- retiro bloqueado;
- liquidación con cálculo exacto del colateral entregado, contra posiciones sanas y
  limitada por el colateral;
- donaciones, oráculo viejo y falta de liquidez;
- validación de parámetros y tasas del kink;
- solvencia y que no se pueda generar dinero gratis (fuzz).


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
