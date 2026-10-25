# 95. Upgradeable Token

**Nivel:** Avanzado · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
ERC20 actualizable vía proxy **UUPS** (ERC-1967) con almacenamiento namespaced **ERC-7201**; upgrade a V2 conservando saldos.

## Archivos
- `src/UpgradeableTokenV1.sol` — lógica ERC20 mínima + `initialize` + `_authorizeUpgrade`.
- `src/UpgradeableTokenV2.sol` — agrega `burn`, `cap`, `mintCapped`, `initializeV2` (`reinitializer(2)`).
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Desplegar `UpgradeableTokenV1` (implementación).
2. Desplegar `ERC1967Proxy(impl, abi.encodeCall(initialize, (...)))`.
3. Interactuar siempre con la dirección del proxy.
4. Upgrade: `proxy.upgradeToAndCall(implV2, abi.encodeCall(initializeV2, (cap)))` (solo owner).

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- `_disableInitializers()` en el constructor de la implementación.
- Inicializar en el mismo despliegue del proxy (evita front-running del `initialize`).
- Nunca reordenar/cambiar tipos del storage; ERC-7201 aísla namespaces (slots verificados en `test_SlotsERC7201`).
- Si una versión no hereda UUPS, el proxy queda congelado para siempre.
- La lógica ERC20 es didáctica; en producción usar `ERC20Upgradeable` de openzeppelin-contracts-upgradeable y el plugin de validación de upgrades.

## Consideraciones de gas
- Cada llamada paga un `delegatecall` extra (~2600 gas frío).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
