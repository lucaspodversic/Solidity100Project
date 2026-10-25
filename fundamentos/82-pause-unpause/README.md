# 82. Pause/Unpause Functionality

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Circuit breaker implementado desde cero: `whenNotPaused` / `whenPaused` y retiro de emergencia.

## Archivos
- `src/PausableVault.sol` — bóveda con `pause`, `unpause`, `deposit`, `withdraw`, `emergencyWithdraw`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
- Guardián: `pause()` ante un incidente, `unpause()` al resolverlo.
- Usuarios: durante la pausa solo `emergencyWithdraw()`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- La pausa es un poder centralizado: idealmente controlado por un multisig (proyecto 94).
- Permitir a los usuarios rescatar fondos en pausa evita que la pausa se convierta en un congelamiento abusivo.
- En producción, usar `Pausable` de OpenZeppelin (ver proyecto 83).

## Consideraciones de gas
- Un `bool` en storage leído por modificador (~2100 gas frío).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
