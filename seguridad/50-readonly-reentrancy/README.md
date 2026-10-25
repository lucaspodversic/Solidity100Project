# 50 — Read-only Reentrancy PoC (Avanzado)

Estilo Curve: durante `removeLiquidity` un view (`getVirtualPrice`) sigue leyendo estado viejo.
Defensa: `require(locked==0)` también en las views críticas.

```bash
forge test -vv
```
