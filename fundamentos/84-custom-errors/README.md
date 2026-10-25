# 84. Custom Errors and Reverts

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Comparativa medida de `require(cond, "string")` vs `error Personalizado(args)`: tamaño de bytecode, gas de reversión y bytes devueltos.

## Archivos
- `src/CustomErrors.sol` — `BankWithStrings` vs `BankWithCustomErrors` + error a nivel archivo `Unauthorized`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
`forge test -vv` imprime bytecode y gas de cada variante.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Los errores con argumentos dan contexto útil para depurar (saldo disponible vs solicitado).
- Desde Solidity 0.8.26 existe `require(cond, Error())`.

## Consideraciones de gas
- Bytecode más chico y revert de solo 4 bytes (selector) cuando no hay argumentos — verificado en `test_RevertMasBarato` y `test_BytecodeMasChico`.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
