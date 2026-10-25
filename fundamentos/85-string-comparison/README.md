# 85. String Comparison in Solidity

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Comparación de strings con `keccak256`, atajo por longitud, bucle byte a byte e insensible a mayúsculas.

## Archivos
- `src/StringUtils.sol` — librería `StringUtils` y contrato de ejemplo `PasswordGame`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
`using StringUtils for string;` y luego `a.equal(b)`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- No usar `abi.encodePacked` con varios strings dinámicos para ids: colisiona (`test_ColisionEncodePacked`).
- Un hash publicado on-chain de una respuesta corta se puede romper por fuerza bruta.

## Consideraciones de gas
- `keccak256` es más barato que el bucle en strings largos (`test_GasHashVsLoop`).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
