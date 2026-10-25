# 37 — Dynamic NFT (Intermedio)

Atributos que cambian según un **mock de Chainlink** (VRF/Data Feed). El `tokenURI` se recalcula on-chain sin storage extra.

## Diseño
- `level = (oracle.latest + seed) % 100` → stage Egg/Hatchling/Adult/Legend.
- Solo el oracle puede `fulfill`. En producción: Chainlink VRF + Functions.

```bash
forge test -vv
```
