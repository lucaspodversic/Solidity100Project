# 80. Time Lock Contract

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Bloqueo de funciones con `block.timestamp`: depósitos con fecha de liberación y operaciones administrativas encoladas con demora mínima y ventana de gracia (estilo Compound Timelock).

## Archivos
- `src/TimeLock.sol` — `deposit`, `extendLock`, `withdraw`, `queue`, `execute`, `cancel`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
- Depósito: `deposit{value: x}(segundos)`; retirar con `withdraw()` cuando venza.
- Admin: `queue(target, value, data, eta)` con `eta ≥ ahora + 2 días`; luego `execute(...)` entre `eta` y `eta + 14 días`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- La demora da tiempo a los usuarios para salir si no están de acuerdo con un cambio.
- El id de operación es `keccak256(abi.encode(...))`: cualquier cambio de parámetros es otra operación.
- Se borra `queued[id]` antes de la llamada externa (anti-reentrancia/replay).
- `block.timestamp` es manipulable unos segundos: aceptable para días, no para segundos.

## Consideraciones de gas
- Mappings simples; `constant` para demoras.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
