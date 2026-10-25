# 79. English Auction

**Nivel:** Principiante/Intermedio · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Subasta inglesa (precio ascendente) con incremento mínimo, extensión anti-sniping y reembolsos *pull*.

## Archivos
- `src/EnglishAuction.sol` — `start()`, `bid()`, `withdraw()`, `settle()`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Vendedor: `new EnglishAuction(reserva, incrementoMin, duracion)` y `start()`.
2. Postores: `bid{value: x}()` (x ≥ `minNextBid()`).
3. Superados: `withdraw()`.
4. Al vencer: cualquiera llama `settle()` y el vendedor cobra.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Pull payments: un postor malicioso que rechaza ETH no puede bloquear la subasta (test `test_PostorMaliciosoNoBloquea`).
- Anti-sniping: una puja en los últimos 10 minutos extiende el cierre.
- En la versión real, el bien subastado (NFT) debería custodiarse en el contrato.

## Consideraciones de gas
- Mapping `pendingReturns` en vez de arrays de postores.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
