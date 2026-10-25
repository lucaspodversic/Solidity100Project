# 55 — Access Control Audit (Intermedio)

Proxy transparente + lógica. Revisa:
- `onlyAdmin` en upgrade/sweep
- `initialize` una sola vez
- `disableInitializers` en la implementación naked (evita takeover del impl)

```bash
forge test -vv
```
