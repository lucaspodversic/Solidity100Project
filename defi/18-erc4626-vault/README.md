# 18 · ERC-4626 Vault (implementación desde cero, con fees)

**Nivel:** Intermedio

Un vault tokenizado **ERC-4626** escrito sin heredar `ERC4626` de OpenZeppelin, para estudiar
la matemática del estándar. Usa solo `ERC20`, `Math`, `SafeERC20`, `Ownable` y
`ReentrancyGuard` de OZ.

## Funcionalidades

| Tema | Implementación |
|---|---|
| Conversión | `shares = assets·(supply + 10^6) / (totalAssets + 1)`, con **shares virtuales** y offset de 6 decimales. |
| Redondeo | `deposit` y `redeem` redondean hacia abajo (recibís menos). `mint` y `withdraw` redondean hacia arriba (pagás o quemás más). Siempre a favor del vault. |
| Management fee | Anual, en bps, cobrada por **dilución**: se acuñan shares al tesoro. Tope del 5 %. |
| Performance fee | Sobre la ganancia por share por encima del **high-water mark**. Tope del 30 %. |
| Fees en las vistas | `preview*` y `convertTo*` incluyen las fees **pendientes**, así nadie entra o sale "esquivando" el cobro. |
| Límites | `depositCap` y `paused` se reflejan en `maxDeposit` y `maxMint`. La pausa **no** bloquea retiros. |
| Retiro de terceros | `withdraw` y `redeem` con `owner ≠ caller` consumen allowance de shares. |

## Diseño de fees

En cada operación se llama primero a `accrueFees()`:

1. **Management fee:** `mgmtShares = supply · fee · Δt / año`. Es una aproximación lineal
   estándar: con el 2 % el tesoro termina con 2/102 ≈ 1,96 % del vault al cabo de un año.
2. **Performance fee:** se compara el precio por share (`pps`) con el HWM.
   - Si `pps` está por encima:
     - `ganancia = (pps − hwm) · supply`;
     - `fee = ganancia · perf`;
     - se acuñan `s` shares tales que `s/(supply+s) = fee/assets`.
   - Luego el HWM pasa a ser el nuevo `pps`, ya neto de la fee.
   - **Si el vault pierde, no se cobra nada hasta que recupere el máximo anterior** (ver
     `test_PerformanceFeeWithHighWaterMark`).
3. Cambiar las fees (`setParams`) cobra primero lo pendiente con las fees **viejas**, para que
   el cambio no sea retroactivo.

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Inflación del primer depósito (1 wei + donación) | shares virtuales + offset de 6: el atacante pierde casi toda la donación | `test_InflationAttackUnprofitable` |
| Ganancia por redondeo (depositar y redimir en el acto) | redondeo a favor del vault | `testFuzz_NoFreeMoney`, `test_RoundingFavorsVault` |
| Entrar justo después de una ganancia sin pagar la performance fee | fees pendientes incluidas en los `preview` | `test_PreviewIncludesPendingFees` |
| Owner que sube las fees al máximo | topes `MAX_MGMT_FEE` y `MAX_PERF_FEE`, cambios no retroactivos | `test_FeeCaps` |
| Fondos encerrados por pausa | la pausa solo frena las entradas | `test_DepositCapAndPause` |
| Reentrada con tokens con hooks | `nonReentrant` + CEI | — |

Los previews coinciden **exactamente** con la ejecución, como exige el estándar (ver
`test_PreviewsMatchExecution`).

> Limitación: `totalAssets` es el saldo del contrato, así que una donación cuenta como
> rendimiento. El proyecto 23 compara este enfoque con la contabilidad interna.

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
