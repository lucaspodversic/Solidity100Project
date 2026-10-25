# 52 — MEV Sandwich Attack Simulation (Avanzado)

Simulación de sandwich sobre un AMM x*y=k.
- **Ataque**: front-run buy → victim → back-run sell → profit del atacante, peor precio para la víctima.
- **Resistencia**: `minOut` (slippage) ajustado; en prod también private relays (Flashbots Protect), TWAMM, etc.

```bash
forge test -vv
```
