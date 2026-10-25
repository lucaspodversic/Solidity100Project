# 57 — Signature Replay Attack PoC (Avanzado)

## Ataque
Firma sin nonce/domain → se reusa (replay) y es válida en otros contratos/chains.

## Defensa
EIP-712: `DOMAIN_SEPARATOR` (name, version, chainId, verifyingContract) + `nonce` incremental.

```bash
forge test -vv
```
