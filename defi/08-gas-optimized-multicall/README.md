# 08 · Gas-Optimized Multicall

**Nivel:** Intermedio

Tres variantes de *multicall*, cada una con su caso de uso y sus riesgos:

| Archivo | Variante |
|---|---|
| `src/Multicall.sol` | Estilo **Multicall3**: `aggregate`, `tryAggregate`, `aggregate3` (fallas por llamada) y `aggregate3Value` (con ETH exacto y reembolso), más getters de bloque y balance. |
| `src/PackedMulticall.sol` | **Calldata empaquetado** `[target 20B][len 2B][data]` vía `fallback`, que reduce el calldata ~6x (clave en rollups). `PackedCodec` codifica y decodifica. |
| `src/SelfMulticall.sol` | Multicall con `delegatecall` a sí mismo (patrón del router de Uniswap V3): preserva `msg.sender`. |
| `src/mocks/Mocks.sol` | Objetivo de prueba, un banco seguro y un banco **vulnerable** para el test del ataque. |

## Diseño y optimizaciones

- Todo se recibe como `calldata`, sin copiar a memoria. Los bucles usan `unchecked { ++i; }`
  con la longitud cacheada.
- `PackedMulticall`:
  - elimina el relleno a 32 bytes y los offsets de la codificación ABI;
  - con 10 llamadas, el calldata baja de **1668 a 260 bytes**;
  - no expone ninguna otra función, para que ningún input empaquetado coincida con un
    selector (los helpers viven en otro contrato);
  - valida los límites (`Malformed`) antes de cada slice.
- Los errores se reportan con el índice de la llamada (`CallFailed(index, reason)`).
  `SelfMulticall` re-lanza el revert original con assembly.

## Incentivos y casos de uso

- **Lecturas masivas** (dashboards, bots): un solo RPC y un estado consistente del mismo bloque.
- **Acciones atómicas** (approve + swap en un router propio, varias operaciones de un vault):
  o se aplica todo o no se aplica nada.
- En **L2** el gas lo domina el calldata publicado en L1. Ahí el formato empaquetado ahorra
  dinero real.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| **Reutilizar `msg.value`** en un multicall payable con delegatecall: un depósito se acredita N veces | `SelfMulticall.multicall` **no es payable**. El test `MsgValueReuseAttackOnVulnerable` muestra el bug: 1 ETH acreditado como 3. |
| ETH sobrante atrapado en el multicall y robado por el siguiente usuario | `aggregate3Value` exige `msg.value == Σ value` y reembolsa el ETH de las llamadas fallidas con `allowFailure`. |
| Aprobar tokens al Multicall genérico | Documentado: `msg.sender` es el multicall, así que cualquiera podría gastar esa aprobación. Nunca aprobarlo. |
| Inputs empaquetados malformados (lectura fuera de rango) | Chequeos de límites y `Malformed`. |
| Colisión de selector con la entrada empaquetada | `PackedMulticall` solo tiene `fallback`. |

## Tests

14 tests (1 de fuzz). Cubren:
- atomicidad;
- tolerancia a fallas;
- valor exacto y reembolso;
- equivalencia del formato empaquetado, entradas malformadas y propagación de errores;
- tamaño del calldata;
- preservación de `msg.sender`;
- el ataque de reutilización de `msg.value` y su defensa.


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
