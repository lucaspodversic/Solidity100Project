# 88. Inheritance Contract

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Herencia para modularizar: contratos abstractos, `virtual`/`override`, `super`, herencia múltiple y linealización C3.

## Archivos
- `src/Base.sol` — `Owned`, `Logger`, `Limited` (abstractos).
- `src/Counter.sol` — `ModularCounter` (compone los tres) y `UnlimitedCounter` (sobrescribe un hook).
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
`ModularCounter.describe()` devuelve `Counter>Limited>Logger>Owned` mostrando el orden de `super`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Listar padres del más base al más derivado.
- Al sobrescribir en herencia múltiple, `override(A, B)` debe nombrar todos los padres.
- Herencias profundas dificultan auditar: preferí composición clara y pocos niveles.

## Consideraciones de gas
- La herencia no agrega costo en ejecución: todo se compila en un solo contrato.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
