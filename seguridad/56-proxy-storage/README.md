# 56 — Proxy Storage Layout Audit (Avanzado)

## Riesgos
1. **Colisión de storage**: lógica usa slot 0 → pisa `admin` del proxy.
2. **Init front-run**: implementación/`initialize` llamado por un atacante primero.

## Defensa
- EIP-1967 (slots keccak), `__gap` en upgradeable, `disableInitializers` en el impl.
- Misma layout entre versiones (OpenZeppelin upgrades plugin).

```bash
forge test -vv
```
