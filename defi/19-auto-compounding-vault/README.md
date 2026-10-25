# 19 · Auto-compounding Vault

**Nivel:** Intermedio

Un vault **ERC-4626** que deposita el token de stake en una granja de rewards y **re-invierte**
los rewards solo. Así el rendimiento se compone: el APR de la granja termina rindiendo como APY.

## Piezas

| Contrato | Rol |
|---|---|
| `AutoCompoundVault` | Hereda `ERC4626` de OZ, con offset de 6 decimales. Stakea en cada depósito y des-stakea en cada retiro. |
| `mocks/StakingFarm` | Granja estilo Synthetix `StakingRewards`. Reparte una tasa de reward por segundo en proporción al stake. |
| `mocks/SimpleAMM` | AMM x·y=k donde se vende el token de reward a cambio del token de stake. |
| `mocks/MockERC20` | Tokens de prueba. |

## Flujo de `harvest(minOut)` (permisionless)

1. `farm.getReward()` reclama los RWD acumulados.
2. `amm.swap(RWD → STK, minOut)` vende los rewards. Si el precio es peor que `minOut`, revierte.
3. Se reparte el resultado:
   - **bounty** al caller (0,5 %), que le paga el gas al keeper;
   - **performance fee** al tesoro (10 %);
   - el resto es ganancia para los holders.
4. La ganancia **se bloquea** y se libera linealmente durante `LOCK_PERIOD = 6 h`.
5. Todo el STK que quedó ocioso se vuelve a stakear.

Durante ese período `totalAssets()` resta `lockedNow()`:

```
totalAssets = stakeado + ocioso − lockedProfit · (LOCK_PERIOD − Δt) / LOCK_PERIOD
```

## Incentivos

- **Keepers:** cualquiera puede llamar a `harvest`. El bounty hace rentable que un bot coseche apenas
  la ganancia supera el costo del gas. `pendingHarvest()` devuelve rewards y valor estimado,
  así el bot decide cuándo conviene.
- **Holders:** con cada harvest ganan una porción mayor de los rewards frente a quien stakea sin
  componer. El test `test_CompoundingBeatsSimpleStaking` lo muestra: con cosecha semanal durante
  un año, alice termina en ≈131 320 y bob (stake directo, vende al final) en ≈128 609.
  Eso pese a que alice paga un 10,5 % de fees.
- **Protocolo:** cobra una performance fee con tope del 20 %. El bounty tiene tope del 3 %.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| **Sandwich del harvest:** depositar justo antes del harvest y retirar justo después para quedarse con parte del salto de precio. | **Locked profit:** la ganancia entra a `totalAssets` de forma gradual. Quien entra y sale en el mismo bloque recupera, como mucho, lo que puso. Lo verifican `test_SandwichHarvestUnprofitable` y `testFuzz_NoFreeMoney`. |
| **Sandwich del swap** RWD→STK en el AMM, en el que un MEV-bot mueve el precio. | `minOut` lo calcula off-chain el keeper (por ejemplo, el 99 % de `pendingHarvest`). Si no se cumple, revierte (`test_SlippageProtection`). |
| **Inflación o donación** sobre el primer depositante. | Shares virtuales: `_decimalsOffset() = 6`. |
| **Reentrancy** desde los tokens o la granja durante el harvest. | `nonReentrant` en `harvest`. Tokens, AMM y granja están fijados como `immutable`. |
| **Fees abusivas.** | Topes duros en `setFees`, que además es `onlyOwner`. |

### Limitaciones conocidas

- El bounty y la fee se pagan en el asset, sin acuñar shares. Es simple, pero reduce un poco
  el capital que se compone.
- Si la granja sufriera una pérdida mayor que `lockedProfit`, `totalAssets` podría hacer
  underflow. En producción conviene usar un `min` defensivo y llevar una contabilidad de pérdidas.
- Los harvests seguidos re-bloquean todo lo pendiente, porque suman la ganancia nueva a lo que
  quedaba bloqueado. Es el comportamiento de Yearn v2.

## Tests (`test/AutoCompoundVault.t.sol`)

| Test | Qué verifica |
|---|---|
| `test_DepositIsStaked` / `test_WithdrawUnstakes` | El capital se stakea al depositar y se des-stakea al retirar. |
| `test_HarvestCompoundsAndPaysBounty` | Montos de bounty, fee y ganancia neta. El precio por share sube. |
| `test_ProfitUnlocksLinearly` | La ganancia está bloqueada al 100 % al cosechar y al 50 % a las 3 h. |
| `test_SlippageProtection` | El harvest revierte con un `minOut` exagerado. |
| `test_NothingToHarvest` | No se puede cosechar si no hay rewards. |
| `test_SandwichHarvestUnprofitable` | Un atacante con 1M no captura la ganancia. |
| `test_CompoundingBeatsSimpleStaking` | Componer gana frente a stakear directo. |
| `test_FeeCaps` | Topes de fee y control de acceso. |
| `testFuzz_NoFreeMoney` | Cualquier monto y tiempo de espera alrededor del harvest da cero de ganancia. |

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
