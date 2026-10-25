# 99. Streaming Payments (Sablier-style)

**Nivel:** Avanzado · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Pagos continuos por segundo: depósito por adelantado que se devenga linealmente; retiro parcial y cancelación con reparto justo.

## Archivos
- `src/PaymentStream.sol` — `createStream`, `streamed`, `withdrawable`, `withdraw`, `cancel`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Emisor: `token.approve(stream, deposito)` y `createStream(receptor, token, deposito, inicio, fin)`.
2. Receptor: `withdraw(id, monto)` cuando quiera.
3. Cualquiera de los dos: `cancel(id)`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Invariante verificada por fuzzing: lo cobrado por el receptor + lo devuelto al emisor = depósito.
- No soporta tokens con fee-on-transfer ni rebasing (el depósito recibido diferiría).
- `SafeERC20` + `ReentrancyGuard`.

## Consideraciones de gas
- Struct empaquetado (uint128/uint64) en 4 slots; nada se ejecuta "por segundo": el saldo se calcula al consultar.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
