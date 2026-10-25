# 97. Dutch Auction

**Nivel:** Intermedio · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Subasta holandesa de un NFT: precio que baja linealmente por segundo hasta un piso; el primero que acepta compra y recibe el excedente.

## Archivos
- `src/DutchAuction.sol` — `DemoNFT` (ERC721) y `DutchAuction`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Vendedor: desplegar la subasta, `nft.approve(subasta, id)`, `start()`.
2. Comprador: consultar `currentPrice()` y llamar `buy{value: x}()`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Se devuelve el excedente porque el precio baja entre la firma y la inclusión de la tx.
- Expuesta a MEV/bots que compran justo al cruzar su valoración.
- NFT en custodia del contrato desde `start()`.

## Consideraciones de gas
- Una sola tx por venta; precio calculado, no almacenado.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
