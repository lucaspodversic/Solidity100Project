# 20 · Multi-strategy Vault

**Nivel:** Avanzado

Es un vault **ERC-4626** que reparte el capital entre varias estrategias de rendimiento, al
estilo de Yearn v2/v3.

## Diseño

| Pieza | Detalle |
|---|---|
| `IStrategy` | Interfaz mínima: `asset`, `totalAssets`, `apyBps`, `invest` y `divest`. |
| Contabilidad por **deuda** | El vault anota cuánto le asignó a cada estrategia (`debt`), y `totalAssets = idle + totalDebt − lockedNow()`. Las ganancias y pérdidas reales recién se reconocen al llamar a `report()`. |
| `allocate()` | Ordena las estrategias por APY, de mayor a menor. Cada una se llena hasta `capBps` del total y se deja una **reserva ociosa** (`reserveBps`, 5 % por defecto) para atender retiros baratos. Trabaja en dos fases: primero des-invierte de las estrategias que están sobre-asignadas y después invierte en las sub-asignadas. |
| `report()` | Reconoce ganancias y pérdidas. Sobre la **ganancia** cobra una performance fee del 10 %, que se paga acuñando shares al tesoro, y bloquea esa ganancia durante 24 h con desbloqueo lineal. La **pérdida** se reconoce en el acto y primero consume la ganancia que todavía está bloqueada. |
| Cola de retiro | Si la reserva no alcanza, el vault des-invierte siguiendo `withdrawQueue`, que el admin puede reordenar. Una estrategia ilíquida que devuelve menos de lo pedido se saltea y se pasa a la siguiente. Si al final la plata no alcanza, la operación **revierte** con `InsufficientLiquidity`. |
| Roles | `DEFAULT_ADMIN_ROLE` agrega y revoca estrategias y fija parámetros. `KEEPER_ROLE` ejecuta `allocate` y `report`. |
| Métrica | `weightedApy()` devuelve el APY ponderado por deuda, pensado para dashboards. |

## Incentivos

- Los depositantes obtienen el mejor APY disponible sin tener que mover fondos por su cuenta,
  y los topes por estrategia limitan la exposición a cualquier protocolo individual.
- El protocolo cobra solamente sobre ganancias realizadas, nunca sobre el principal.
- La reserva ociosa le cuesta algo de rendimiento al vault, pero hace que los retiros chicos
  sean baratos, porque no hace falta des-invertir.

## Ataques y defensas

| Riesgo | Defensa |
|---|---|
| **Sandwich del `report`:** entrar justo antes de que se reconozca una ganancia. | La ganancia se libera linealmente durante 24 h (`test_SandwichReportUnprofitable`). |
| **Salida anticipada ante una pérdida:** los informados retiran a precio viejo. | La pérdida se reconoce inmediatamente y no se demora como las ganancias. |
| **Estrategia ilíquida o maliciosa.** | Topes por estrategia, revocación (`revokeStrategy` exige poder sacar todo), y `divest` solo puede llamarlo el vault (`OnlyVault`). |
| **Retiro que deja la pérdida a los demás.** | Si no se consigue liquidez suficiente, revierte en vez de pagar de menos. |
| **Inflación de shares.** | `_decimalsOffset() = 6`. |
| **APY reportado falso** por una estrategia. | Es una limitación de confianza: el APY viene de la propia estrategia. Lo mitigan los topes y la whitelist del admin. En producción conviene calcular el APY realizado a partir de los `report`. |
| **Reentrancy** desde las estrategias. | `nonReentrant` en `allocate`, `revokeStrategy` y `_withdraw`. |

## Tests (`test/MultiStrategyVault.t.sol`, 15)

- Asignación por APY y topes, y reasignación cuando cambia un APY.
- Ganancia con fee y desbloqueo lineal; pérdida inmediata; pérdida que consume la ganancia bloqueada.
- Sandwich del report sin ganancia para el atacante.
- Cola de retiro estándar y personalizada, salto de estrategias ilíquidas y revert por falta de liquidez.
- Revocación de estrategias, validación al agregarlas, control de acceso y fuzz de ida y vuelta.

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
