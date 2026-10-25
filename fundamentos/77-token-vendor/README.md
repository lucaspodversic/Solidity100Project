# 77. Token Vendor

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Compra/venta de un ERC20 a precio fijo con transferencias seguras contrato-a-contrato (`SafeERC20`) y el flujo `approve` + `transferFrom`.

## Archivos
- `src/VendorToken.sol` — ERC20 (OpenZeppelin) con suministro inicial.
- `src/Vendor.sol` — máquina expendedora: `buyTokens()`, `sellTokens(amount)`, `withdraw()`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Desplegar `VendorToken(supply)` y `Vendor(token)`.
2. Transferir inventario de tokens al Vendor.
3. Comprar: `vendor.buyTokens{value: 1 ether}()` → 100 tokens.
4. Vender: `token.approve(vendor, x)` y luego `vendor.sellTokens(x)`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- `SafeERC20` cubre tokens que no devuelven `bool` (USDT) y revierte en fallos silenciosos.
- `ReentrancyGuard` + CEI al enviar ETH.
- Precio fijo: no hay oráculo ni protección ante cambios de mercado; el dueño debe mantener liquidez de ETH para recompras.
- La división entera redondea a favor del contrato.

## Consideraciones de gas
- Un solo `balanceOf` por compra.
- `constant`/`immutable` para precio y token.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
