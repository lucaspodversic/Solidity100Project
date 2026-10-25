# 49 — Reentrancy Attack & Defense (Intermedio)

## Ataque
`withdraw` envía ETH antes de poner balance=0 → el `receive` del atacante reentra y drena.

## Defensa
1. **CEI**: Effects (balance=0) antes de Interactions (call).
2. **Mutex** `nonReentrant`.

```bash
forge test -vv
```
