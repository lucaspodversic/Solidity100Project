# 61 · Gas Estimation Experiment (Principiante/Intermedio)

Laboratorio que implementa **la misma operación** ("guardar un usuario con id, saldo y flag") con distintas estructuras de datos y mide el gas de cada una.

## Estructura

| Ruta | Qué hay |
|---|---|
| `src/GasLab.sol` | `ArrayStore`, `MappingStore`, `PackedMappingStore`, `ParallelMappingsStore` y `MicroOpts` (bucles, memory/calldata, errores). |
| `test/GasLab.t.sol` | 8 tests: correctitud + mediciones con `gasleft()` que se imprimen con `-vv`. |
| `GAS_REPORT.md` | Salida de `forge test --gas-report` (ya generada). |

```bash
forge test -vv            # tabla de mediciones en los logs
forge test --gas-report   # reporte por función (gas_reports = ["*"] en foundry.toml)
```

## Resultados (medidos con 50 usuarios precargados)

| Operación | Array de structs | Mapping (struct suelto, 3 slots) | Mapping (struct empaquetado, 1 slot) | Mappings paralelos |
|---|---:|---:|---:|---:|
| Insertar | 98.137 | 93.145 | **49.125** | 70.951 |
| Buscar el último | 127.644 (O(n)) | **7.441** | 7.663 | — |
| Actualizar saldo | 151.840 | 31.629 | 31.821 | **31.623** |

| Micro-optimización | Ingenuo | Optimizado |
|---|---:|---:|
| Bucle de 100 elementos (length cacheado + acumulador en memoria + `unchecked`) | 317.602 | **269.572** |
| Array de 64 uint256 como argumento: `memory` vs `calldata` | 27.476 | **21.990** |
| `revert("string")` vs error personalizado | 5.310 | **5.227** (y menos bytecode) |

> Los números incluyen el overhead de la llamada externa. Pueden variar ±1% entre versiones de solc.

## Conclusiones

1. **Empaquetar los structs** (uint64 + uint128 + bool en un slot) casi duplica la eficiencia de inserción: 1 SSTORE de slot nuevo (22.1k) en vez de 3.
2. **Mapping > array** para buscar por clave: el array es O(n) y con 50 elementos ya cuesta 17 veces más. Usá arrays solo si necesitás iterar, y en ese caso combiná un mapping (índice) con un array (enumeración).
3. **Leer un campo empaquetado** cuesta un poco más (máscaras/shift), así que si un campo se escribe muy seguido y solo, los mappings paralelos pueden convenir.
4. **Evitá escribir storage dentro de bucles**: acumulá en memoria y escribí una vez.
5. **Usá `calldata`** en funciones `external` que solo leen arrays.
6. **Los errores personalizados** ahorran poco en runtime pero bastante en tamaño de despliegue.

## Seguridad

- `unchecked { ++i; }` es seguro solo porque `i < len` acota el índice. **Nunca** uses `unchecked` en aritmética de saldos.
- Los bucles sobre arrays que crecen sin límite (`ArrayStore.find`) son un **vector de DoS**: con suficientes elementos superan el gas del bloque. Por eso en producción se prefieren mappings o paginación.
- Al empaquetar en tipos chicos hay que verificar que los valores entren (`uint128` alcanza para saldos de 18 decimales, `uint64` para ids/timestamps). El fuzz `testFuzz_PackedRoundtrip` lo valida en todo el rango.
