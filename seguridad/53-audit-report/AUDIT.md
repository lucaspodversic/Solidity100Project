# Informe de auditoría — VaultManager

**Alcance:** `src/VaultManager.sol`  
**Fecha:** 2026-10-25  
**Metodología:** revisión manual + PoCs en Foundry

## Resumen

| Severidad | Cantidad |
|---|---|
| Critical/High | 2 |
| Medium | 2 |
| Low | 1 |

## Hallazgos

### H-01 — `setOwner` sin control de acceso (Critical)
Cualquiera puede tomar ownership. **Fix:** `onlyOwner` + check `!= 0`.

### H-02 — Reentrancy en `withdraw` (Critical)
El ETH se envía antes de actualizar `balances`. **Fix:** CEI + mutex.

### M-01 — `setPaused` sin `onlyOwner` (Medium)
Un atacante puede DoS el vault pausándolo. **Fix:** `onlyOwner`.

### M-02 — Desync potencial `totalDeposits` / `balances` (Medium)
Si hubiera otra vía de salida de ETH, el contador quedaría inconsistente. **Fix:** derivar de `address(this).balance` o invariantes en tests.

### L-01 — Sin eventos (Low)
Dificulta indexación. **Fix:** emitir `Deposit`/`Withdraw`.

## Parches
Ver `VaultManagerFixed.sol`. Tests en `test/Audit.t.sol` demuestran el exploit y el fix.
