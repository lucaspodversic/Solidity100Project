# 36 — NFT Liquidity Platform (Avanzado)

Pool estilo AMM/bonding curve para una colección: LPs depositan NFTs+ERC20, traders compran/venden al spot.

## Diseño
- Curva: `spot ≈ base + slope * scarcity` ± fee.
- `deposit` → shares; `withdraw` retira proporción de la reserva de tokens.
- ReentrancyGuard en todas las ops que mueven assets.

```bash
forge test -vv
```
