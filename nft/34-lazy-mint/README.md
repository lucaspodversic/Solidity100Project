# 34 — Lazy Minting NFT Marketplace (Avanzado)

Acuñación **perezosa** con vouchers **EIP-712**: el creador firma off-chain; el comprador paga y acuña on-chain.

## Diseño
- `Voucher{tokenId, price, buyer, uri}` firmado por `minter`.
- `buyer = address(0)` → cualquiera; si no, solo ese address.
- Cada `tokenId` se marca `voucherUsed` (anti-replay).
- Dominio EIP-712 evita que la firma se reuse en otra chain/contrato.

```bash
forge test -vv
```
