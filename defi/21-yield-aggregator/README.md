# 21 · Yield Aggregator

**Nivel:** Intermedio

Registro on-chain de fuentes de rendimiento ERC-4626 del mismo asset. El contrato **mide** el
APY de cada fuente, la compara por **APY, TVL y riesgo**, publica un **ranking** y ofrece un
**router** que deposita en la mejor opción.

## Diseño (`src/YieldAggregator.sol`)

| Concepto | Cómo se calcula |
|---|---|
| Precio por share (pps) | `vault.convertToAssets(10^decimals)`. |
| APY medido | `poke()` es permisionless y toma una foto del pps de cada fuente cuando pasaron al menos `MIN_WINDOW = 1 h` desde la anterior. La muestra se calcula como `(pps/pps_prev − 1) · año/Δt` (bps, interés simple anualizado). Se suaviza con una EMA: `apy = 0,7·apy + 0,3·muestra`. Si el pps baja, la muestra vale 0. |
| Riesgo | Lo asigna la gobernanza (`riskBps`, entre 0 y 10 000). Puede salir de auditorías, de la antigüedad del protocolo, de la dependencia de oráculos, etc. |
| Score | `apy · (1 − riesgo)`, es decir, el rendimiento ajustado por riesgo. |
| Elegibilidad | La fuente tiene que estar activa, tener al menos una medición, `TVL ≥ minTvl` y `apy ≤ MAX_SANE_APY` (200 %). |
| Ranking | Pone las elegibles primero y después ordena por score descendente. `row(id)`, `ranking()` y `best()` son vistas pensadas para frontends. |
| Router | `depositBest(assets, receiver, minShares)` deposita en `best()`. Las shares van directo al usuario y el allowance se vuelve a 0. |

## Ejemplo (`forge script script/Ranking.s.sol -vv`)

```
#  | fuente             | APY bps | riesgo bps | TVL USDC   | score bps | elegible
1  | Degen farm | 4499 | 7000 | 829589 | 1349 | si
2  | Curve LP | 899 | 1500 | 2014794 | 764 | si
3  | Blue-chip lending | 449 | 200 | 5018493 | 440 | si
4  | Vault nuevo | 1999 | 3000 | 40657 | 1399 | no
Mejor opcion: Degen farm
```

"Vault nuevo" tiene buen score, pero queda descartado por TVL insuficiente. "Degen farm" gana
aunque tiene un 70 % de riesgo, porque su APY es diez veces mayor. Calibrar el riesgo es tarea
de la gobernanza.

## Incentivos

- **Keepers:** llamar a `poke` es barato, y quien depende del ranking, como el router o un
  frontend, tiene motivos para mantenerlo actualizado.
- **Usuarios:** obtienen el mejor rendimiento ajustado por riesgo con una sola transacción y
  sin pagar fees, porque el agregador no custodia nada.
- **Vaults listados:** compiten por APY real medido, no por el que declaran ellos mismos.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| **APY declarado falso.** | No existe: el APY se **mide** a partir del pps. |
| **Donación** al vault para inflar el pps y atraer depósitos (por ejemplo, porque el atacante tiene shares o quiere llevar el TVL a un vault vulnerable). | Lo atenúan la EMA, la ventana mínima, el tope `MAX_SANE_APY` (por encima, la fuente pasa a no elegible) y el filtro de `minTvl`. Lo prueba `test_DonationSpikeMakesSourceIneligible`. |
| **Ventana muy corta** para manipular la medición. | `MIN_WINDOW`: si no pasó suficiente tiempo, `poke` ignora la fuente. |
| **Vault con poco TVL**, fácil de manipular o recién lanzado. | `minTvl`. |
| **Slippage o front-running** del depósito, por ejemplo un ataque de inflación sobre un vault vacío. | `minShares` en `depositBest`. |
| **Allowance residual** que un vault malicioso podría usar después. | Se hace `forceApprove(v, 0)` después de depositar. |

### Limitaciones

- El riesgo es un parámetro de gobernanza y, por lo tanto, depende de la confianza en ella.
- La EMA reacciona con retraso cuando el rendimiento cambia de verdad.
- `poke` recorre todas las fuentes (`MAX_SOURCES = 20`).
- Solo se miden vaults ERC-4626. Otras fuentes necesitarían un adapter que exponga un pps.

## Tests (`test/YieldAggregator.t.sol`, 11)

Cubren: que no haya fuente elegible antes de medir, el ranking por score con el filtro de TVL,
la ventana mínima, la donación detectada, la EMA, las pérdidas, los cambios de gobernanza, el
router (recibe las shares y no deja allowance), el slippage, la validación de fuentes y un fuzz
que compara el APY medido contra el APR simulado (±5 bps).

Script: `forge script script/Ranking.s.sol -vv`.

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
