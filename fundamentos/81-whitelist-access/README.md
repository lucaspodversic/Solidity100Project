# 81. Whitelist Access Control

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Funciones restringidas a una lista blanca on-chain (`mapping(address => bool)`) administrada por el owner.

## Archivos
- `src/Whitelist.sol` — `add`, `addBatch`, `remove`, `claim` (ejemplo restringido) y modificador `onlyWhitelisted`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Owner: `add(cuenta)` o `addBatch([..])`.
2. Cuenta listada: `claim()` (una vez).

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- `Ownable` de OpenZeppelin para la administración.
- Altas idempotentes (no duplican el contador).
- `addBatch` con listas enormes puede exceder el gas del bloque: para miles de direcciones usar Merkle (proyecto 93).

## Consideraciones de gas
- Cada alta cuesta ~22k gas (SSTORE 0→1); borrar devuelve parte (refund).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
