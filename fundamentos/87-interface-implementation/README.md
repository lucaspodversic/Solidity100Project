# 87. Interface Implementation

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Interfaces para desacoplar contratos: un consumidor usa `IPriceOracle` y puede cambiar de implementación sin redeploy; uso de `IERC20` estándar.

## Archivos
- `src/IPriceOracle.sol` — interfaz.
- `src/Oracles.sol` — `ManualOracle` y `FixedOracle`.
- `src/PriceConsumer.sol` — consumidor.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
`new PriceConsumer(oracle)`; `valueOf(asset, amount)`; `setOracle(otro)`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Una interfaz no garantiza comportamiento: el owner debe confiar en la implementación que configura.
- `type(I).interfaceId` = XOR de selectores (base de ERC-165).

## Consideraciones de gas
- Llamada externa: ~2600 gas de acceso frío a la cuenta + la ejecución.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
