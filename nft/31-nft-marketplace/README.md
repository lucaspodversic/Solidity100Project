# 31 — NFT Marketplace (Intermedio/Avanzado)

Marketplace de ERC721 con listado a precio fijo, comisión en bps y **protección reentrancy**.

## Diseño
- Al `list` el NFT se custodia en el contrato (escrow).
- `buy` aplica CEI + `nonReentrant`: desactiva el listado, transfiere el NFT y paga vendedor + fee.
- Comisión máxima 10% (`feeBps ≤ 1000`).

## Ataques y defensa
| Ataque | Defensa |
|---|---|
| Reentrancy en `buy` vía `receive` del vendedor/fee | `nonReentrant` + CEI (desactivar antes de pagar) |
| Compra con pago incorrecto | exige `msg.value == price` |
| Cancelación por terceros | solo el `seller` |

```bash
forge test -vv
```
