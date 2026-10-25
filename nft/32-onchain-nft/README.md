# 32 — On-chain NFT (Avanzado)

Metadatos **SVG 100% on-chain**: el `tokenURI` es un data URI JSON cuyo `image` es un SVG base64.
Sin IPFS ni storage externo. Ideal para colecciones pequeñas (el gas escala con el SVG).

## Diseño
- Semilla = `keccak(prevrandao, ts, minter, id)` → hue/sat/light + rareza.
- `Base64` de OpenZeppelin para embebido.
- **Limitación**: `prevrandao` es manipulable por validadores; para rareza crítica usar Chainlink VRF.

```bash
forge test -vv
```
