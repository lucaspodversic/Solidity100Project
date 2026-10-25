# 23 · Vault Share Accounting: ataques de donación y redondeo

**Nivel:** Intermedio

El proyecto muestra tres vaults con distintos niveles de defensa. Cada ataque tiene un test
donde **sale bien** contra el vault ingenuo y otro donde **fracasa** contra las versiones
defendidas.

| Contrato | Defensas |
|---|---|
| `NaiveVault` ❌ | Ninguna. Cuenta los activos con `balanceOf`, el primer depósito es 1:1 sin offset y `withdraw` redondea hacia abajo. |
| `OffsetOnlyVault` ⚠️ | `ERC4626` de OZ con **shares virtuales** (offset 6). Sigue usando `balanceOf`. |
| `SafeVault` ✅ | Contabilidad **interna**, shares virtuales, redondeo a favor del vault, `require(shares > 0)` y variantes con slippage (`depositWithMin` y `redeemWithMin`). Además, `skim` y `reportYield` para manejar los excedentes. |

## Ataque 1: inflación por donación (front-running del primer depósito)

1. El vault está vacío. El atacante deposita **1 wei** y recibe 1 share.
2. El atacante **dona** 10 000 USDC con una `transfer` directa. Ahora `totalAssets` vale
   10 000e6 + 1 y el supply sigue en 1.
3. La víctima deposita 10 000 USDC y recibe `10 000e6 · 1 / (10 000e6 + 1) = 0` shares.
4. El atacante redime su share y se lleva **20 000 USDC**.

| Vault | Resultado (test) |
|---|---|
| Naive | La víctima recibe **0 shares** y el atacante gana exactamente su depósito (`test_Naive_InflationAttackSucceeds`, más un fuzz). |
| OffsetOnly | `shares = assets·(supply + 10^6)/(totalAssets + 1)`. La víctima recibe shares y pierde solo polvo de redondeo (< 0,0001 %). El **atacante pierde ≈50 % de la donación**, que queda del lado de las shares virtuales. Fuzz: el atacante nunca gana. |
| Safe | La donación **no cuenta**: el precio por share no cambia, la víctima recupera exactamente su depósito y la donación termina en el tesoro vía `skim`. |

¿Por qué alcanza el offset? Para que la víctima redondee a 0, el atacante necesita que
`totalAssets > assets_víctima · (supply + 10^6)`. Es decir, tendría que donar un millón de
veces el monto que quiere robar, y gran parte de esa donación la pierde.

## Ataque 2: retiro de polvo por redondeo

Con `pps > 1`, la fórmula de `NaiveVault.withdraw(1)` da `shares = floor(1 · supply / totalAssets) = 0`.
El atacante **no tiene shares** y aun así retira 1 wei por llamada (`test_Naive_RoundingDrain`:
50 wei en 50 llamadas). En un vault con tokens de pocos decimales o pps alto, cada wei puede
valer bastante. Sumado a operaciones en lote o a una L2 barata, el ataque se vuelve rentable.

La defensa está en el redondeo de OZ ERC-4626, que siempre favorece al vault:

| Función | Redondeo | Efecto |
|---|---|---|
| `deposit` / `previewDeposit` | hacia abajo | recibís ≤ shares |
| `mint` / `previewMint` | hacia arriba | pagás ≥ assets |
| `withdraw` / `previewWithdraw` | hacia arriba | quemás ≥ shares, nunca 0 |
| `redeem` / `previewRedeem` | hacia abajo | recibís ≤ assets |

`test_Safe_RoundingDirections` verifica las cuatro y `test_Safe_RoundingDrainFails` verifica
el revert.

## Otras defensas

- **Shares muertas ("dead shares"):** es la variante de Uniswap V2. En el primer depósito se
  queman `MINIMUM_LIQUIDITY` shares a `address(0)`. Tiene el mismo efecto económico que el
  offset, pero el costo lo paga el primer depositante. Acá preferimos el offset porque no le
  cobra a nadie.
- **Depósito semilla:** el deployer deposita un monto inicial en la misma transacción que el
  deploy.
- **Slippage del usuario:** `depositWithMin` protege aunque el resto falle
  (`test_Safe_SlippageProtection`).
- **`require(shares > 0)`:** un depósito que no da shares revierte en lugar de regalar la plata.

## Incentivos y trade-offs

- La contabilidad interna impide que las donaciones o los "airdrops" lleguen a los holders, y
  por eso hacen falta `reportYield` y `skim`. Para no reabrir un sandwich en un vault real,
  `reportYield` debería tener un desbloqueo gradual (ver los proyectos 19 y 20).
- El offset de 6 agrega decimales a las shares: una share pasa a tener 12 decimales sobre
  USDC, lo que es solo cosmético.

## Tests (`test/ShareAccounting.t.sol`, 11)

- 3 tests de inflación (naive, offset y safe) más el revert por 0 shares.
- 3 tests de redondeo (drain, drain que falla y direcciones de redondeo).
- 1 test de slippage.
- 3 fuzz: el naive siempre es vulnerable; en safe la víctima no pierde nada y el atacante
  nunca gana; en offset el atacante nunca gana.

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
