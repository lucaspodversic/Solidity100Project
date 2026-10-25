# 30 — Simple NFT (Principiante)

Colección **ERC721 completa** basada en OpenZeppelin v5: mint público pago, mint del dueño,
límite por billetera, suministro máximo, metadata con **revelado** (hidden URI → baseURI) y retiro de fondos.

## Diseño
| Pieza | Detalle |
|---|---|
| `SimpleNFT.sol` | ERC721Enumerable + Ownable. Ids desde 1. |
| `mint(q)` | Requiere venta activa, pago exacto `price*q`, `q ≤ 5` por billetera y no superar `maxSupply`. |
| `tokenURI` | Antes de `reveal` devuelve la URI oculta; después `baseURI + id + ".json"`. |
| `withdraw` | Solo dueño, usa `call` y revisa el resultado. |

## Incentivos
- Precio fijo y límite por billetera para distribución más justa.
- Revelado posterior para evitar que los bots elijan tokens raros mirando la metadata antes del mint.

## Ataques posibles y mitigación
- **Reentrancy en mint**: se usa `_mint` (sin callback `onERC721Received`) y los contadores se actualizan antes de acuñar.
- **Sobrepago/infrapago**: se exige `msg.value == costo` exacto (no quedan restos atrapados).
- **Sybil** (muchas billeteras): el límite por wallet no lo evita del todo; en producción se combinaría con allowlist (Merkle) — ver proyecto 34 para firmas.
- **Retiro de fondos por terceros**: `onlyOwner`.

## Uso
```bash
forge build
forge test -vv
```
