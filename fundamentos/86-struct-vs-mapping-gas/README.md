# 86. Struct vs Mapping Gas Cost

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Comparativa de costos de almacenamiento: struct empaquetado (1 slot), struct sin empaquetar (4 slots), mappings separados y array de structs.

## Archivos
- `src/StorageLayouts.sol` — `PackedStruct`, `UnpackedStruct`, `SeparateMappings`, `StructArray`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
`forge test -vv --gas-report` para ver los logs de gas y la tabla por función.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Buscar en arrays es O(n): riesgo de DoS por gas.
- El test `test_SlotsOcupados` usa `vm.load` para comprobar cuántos slots ocupa cada layout.

## Consideraciones de gas
- Primera escritura: 1 slot nuevo (~22k) vs 4 slots (~88k).
- Ordenar los campos de menor a mayor tamaño para que se empaqueten.
- Actualizar un solo campo cuesta parecido en ambos casos (1 slot).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
