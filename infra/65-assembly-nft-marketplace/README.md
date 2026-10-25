# 65 · Marketplace de NFTs con Inline Assembly (Infra)

El mismo marketplace (listar, cancelar, comprar, retirar comisiones) escrito dos veces:

- `src/SolidityMarket.sol`: versión idiomática, la **referencia legible**.
- `src/AsmMarket.sol`: versión con las rutas calientes en **Yul / inline assembly**.

Los tests comparan funcionalidad, seguridad y gas, e incluyen un fuzz **diferencial** que obliga a ambas versiones a dar los mismos resultados.

```bash
forge test -vv              # imprime la comparación de gas
forge test --gas-report     # ver GAS_REPORT.md
```

## Resultados (medidos en `test_GasComparison`)

| Operación | Solidity | Assembly | Ahorro |
|---|---:|---:|---:|
| `list` | 85.022 | 60.129 | **−29%** |
| `buy`  | 139.698 | 94.409 | **−32%** |

## De dónde sale el ahorro

1. **Empaquetado en 1 slot**: `seller (160 bits) | price (96 bits)`. Ahorra un SSTORE en frío (~22k gas) al listar. Es la ganancia más grande, y también podría lograrse en Solidity con `struct { address; uint96; }`.
2. **Lock de reentrada en transient storage** (`tstore`/`tload`, EIP-1153, Cancun): ~200 gas contra miles de un SSTORE.
3. **Llamadas externas sin ABI encoder/decoder**: el calldata se arma a mano en memoria libre y el retorno se lee del scratch space.
4. **Errores y eventos en assembly**: `mstore + revert(0x1c, 4)` y `log4`.
5. **Slot de mapping calculado a mano** con `keccak256` en el scratch space.

## Seguridad: los riesgos del assembly y cómo se mitigan

| Riesgo | Mitigación |
|---|---|
| Sin chequeos de overflow | `price < 2^96`, así que `price * 250` nunca desborda. Las comisiones acumuladas no pueden superar el suministro de ETH. |
| `call` a una dirección sin código "tiene éxito" | En `buy` se verifica `extcodesize(nft)`. En `list`, `ownerOf` exige `returndatasize >= 32`. |
| Leer basura de `returndata` | Se valida siempre `returndatasize` antes de usar `mload(0)`. |
| Corrupción de memoria | Solo se usa el scratch space (0x00–0x3f) y memoria por encima de `0x40`, sin moverla. Por eso los bloques son `memory-safe`. |
| Colisión de slots | Los slots de listados son `keccak256(nft . (id ^ "LIST"))`, imposibles de colisionar con `accruedFees` (slot 0). |
| Topics de eventos mal escritos | `test_EventTopicsMatch` decodifica con el ABI estándar. |
| Reentrada del vendedor al cobrar | CEI (el listado se borra antes de interactuar) más el lock transitorio. Ver `test_ReentrancyBlocked`. |
| Listado obsoleto (el NFT se vendió por fuera) | `transferFrom` revierte y se propaga el motivo. Ver `test_StaleListingReverts`. |
| Divergencia lógica entre versiones | Fuzz diferencial `testFuzz_Differential`. |

## Incentivos

- La comisión del 2,5% se acumula y se retira con *pull* (`withdrawFees`) hacia una dirección inmutable.
- El vendedor cobra en el mismo `buy`. Si su `receive` revierte, solo bloquea su propia venta (no hay DoS para terceros).

## Cuándo NO usar assembly

Bajar de nivel quita las protecciones del compilador. La regla de este repo es: **primero una versión Solidity testeada, después assembly validado contra ella con fuzz diferencial**, y solo en las rutas donde el ahorro justifica el riesgo de auditoría.
