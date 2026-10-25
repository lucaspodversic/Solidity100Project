# 83. Role Management System

**Nivel:** Intermedio · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Control de acceso por roles (admin / minter / pauser) con `AccessControl` de OpenZeppelin, aplicado a un ERC20 pausable.

## Archivos
- `src/RoleToken.sol` — ERC20 + AccessControl + Pausable; hook `_update` bloqueado en pausa.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. `new RoleToken(admin)`.
2. Admin: `grantRole(MINTER_ROLE, x)`, `grantRole(PAUSER_ROLE, y)`.
3. Minter: `mint(to, amount)`. Pauser: `pause()` / `unpause()`.
4. Revocar: `revokeRole`; renunciar: `renounceRole`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Principio de menor privilegio: el admin no acuña ni pausa sin el rol correspondiente.
- El rol admin debería ser un multisig o timelock.
- Perder el admin (renunciar sin sucesor) congela la gestión de roles.

## Consideraciones de gas
- Roles como `bytes32` constantes (hash calculado en compilación).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
