# 33 — NFT con Royalties ERC2981 (Intermedio)

ERC721 + **ERC2981** y marketplace que consulta `royaltyInfo` al vender y reparte automáticamente.

## Diseño
- Royalty default de colección + override por token.
- Marketplace escrow: al `buy` paga royalty al `receiver` y el resto al seller.
- Si el NFT no implementa ERC2981, la royalty es 0 (try/catch).

```bash
forge test -vv
```
