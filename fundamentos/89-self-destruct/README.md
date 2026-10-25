# 89. Self-destruct Contract

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Autodestrucción y envío de fondos **tras EIP-6780** (Cancun): `selfdestruct` ya no borra código/almacenamiento salvo en la misma tx de creación.

## Archivos
- `src/SelfDestruct.sol` — `Destructible`, `SameTxFactory`, `ForceSendVictim`, `ForceSender`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
`forge test` (evm_version = cancun). El compilador emite un warning de deprecación de `selfdestruct`: es esperado y didáctico.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- `selfdestruct` sigue pudiendo forzar ETH a cualquier contrato: no uses `address(this).balance` como invariante (`test_EthForzadoRompeInvariante`).
- Para "apagar" un contrato usá un flag `closed` + retiro de fondos.
- Patrones metamórficos (CREATE2 + redeploy) ya no funcionan.

## Consideraciones de gas
- Ya no hay reembolso de gas por `selfdestruct` (eliminado en EIP-3529).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
