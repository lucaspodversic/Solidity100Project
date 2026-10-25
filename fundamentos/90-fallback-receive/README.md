# 90. Fallback & Receive Functions

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Cómo un contrato maneja ETH entrante (`receive`) y llamadas con selector desconocido (`fallback`), y diferencias entre `transfer`, `send` y `call`.

## Archivos
- `src/EtherReceiver.sol` — `EtherReceiver`, `NoEtherAccepted`, `Sender`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
Ver el diagrama de decisión en el NatSpec de `EtherReceiver`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- `transfer`/`send` reenvían 2300 gas: fallan contra receptores que escriben storage (tests `test_TransferFallaPorGas`, `test_SendDevuelveFalse`).
- Usar `call{value:}` y chequear el retorno, con protección de reentrancia.
- Un `fallback` permisivo puede ocultar errores de llamadas mal formadas.

## Consideraciones de gas
- `receive` vacío es lo más barato para aceptar ETH.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
