# 51 — Oracle Manipulation PoC (Avanzado)

## Ataque
Flash-loan (simulado) mueve el spot de un AMM; el lending que usa spot deja pedir de más.

## Defensa
TWAP / EMA actualizado en txs distintas: en la misma tx el promedio no se mueve (`dt==0`).

```bash
forge test -vv
```
