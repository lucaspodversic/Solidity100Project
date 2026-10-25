# 96. Gasless Meta-Transactions (EIP-2771)

**Nivel:** Avanzado · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Meta-transacciones: el usuario firma una `ForwardRequest` EIP-712 y un relayer paga el gas a través de un forwarder de confianza (`ERC2771Forwarder` de OpenZeppelin).

## Archivos
- `src/Forwarder.sol` — forwarder (dominio `GaslessForwarder`, versión `1`).
- `src/GaslessToken.sol` — ERC20 + `ERC2771Context` (usa `_msgSender()`).
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Desplegar `Forwarder` y `GaslessToken(forwarder)`.
2. El usuario firma con `eth_signTypedData_v4` la estructura `ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)`.
3. El relayer llama `forwarder.execute(requestData)` pagando el gas.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Confiar solo en forwarders auditados; un forwarder malicioso suplanta a cualquiera.
- Nonces y deadline evitan replays (`test_NoReplay`, `test_RevertDeadlineVencido`).
- Usar `_msgSender()` en todo el contrato, nunca `msg.sender`.
- Cuidado con ERC-2771 + Multicall (vulnerabilidad de diciembre 2023, corregida en OZ ≥ 4.9.4/5.0.1).

## Consideraciones de gas
- El relayer paga verificación de firma (~3k gas `ecrecover`) + overhead del forwarder.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
