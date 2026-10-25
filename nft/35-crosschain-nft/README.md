# 35 — Cross-chain NFT Marketplace (Avanzado)

Simulación de NFT multi-cadena con **MockBridge** (lock/mint + burn/unlock) y fee de gas.

## Diseño
- `bridgeOut`: lockea el NFT en origen y emite mensaje.
- Relayer llama `deliver` → `bridgeIn` en destino acuña el espejo.
- `bridgeBack`: quema el espejo y desbloquea el original.
- Anti-replay: `delivered[hash]` en el bridge.

En producción: LayerZero/CCIP/Axelar con verificación criptográfica real.

```bash
forge test -vv
```
