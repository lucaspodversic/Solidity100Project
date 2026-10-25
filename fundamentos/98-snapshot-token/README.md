# 98. Snapshot Token

**Nivel:** Avanzado · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
ERC20 con snapshots de balances (re-implementación didáctica del `ERC20Snapshot` de OZ v4) para votaciones sin doble voto.

## Archivos
- `src/SnapshotToken.sol` — `snapshot()`, `balanceOfAt`, `totalSupplyAt`, hook `_update` y búsqueda binaria.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Owner: `id = snapshot()` al crear una propuesta.
2. Los votos se ponderan con `balanceOfAt(votante, id)`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Snapshot restringido al owner: si fuese público, se podría spamear para encarecer transferencias.
- Mitiga ataques de gobernanza con flash loans (los tokens prestados después del snapshot no cuentan).
- Alternativa moderna en OZ v5: `ERC20Votes` (checkpoints por bloque/tiempo + delegación).

## Consideraciones de gas
- Snapshot O(1); cada primera transferencia por snapshot agrega 2 escrituras por cuenta; consulta O(log n).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
