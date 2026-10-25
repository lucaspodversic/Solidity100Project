# 94. Multi-sig Transaction Execution

**Nivel:** Intermedio · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Billetera M-de-N: proponer, confirmar, revocar y ejecutar transacciones arbitrarias; la administración solo se cambia vía la propia multisig.

## Archivos
- `src/MultiSigWallet.sol`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. `new MultiSigWallet([a,b,c], 2)`.
2. `submit(to, value, data)` (confirma el proponente).
3. Otro dueño: `confirm(id)`.
4. Cualquier dueño: `execute(id)`.
5. Cambiar dueños/umbral: `submit(address(wallet), 0, abi.encodeCall(addOwner, (x)))`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- `executed = true` antes de la llamada externa.
- `onlySelf` impide que un dueño individual cambie las reglas.
- En producción usar Safe (auditada, firmas off-chain, módulos).

## Consideraciones de gas
- Confirmaciones on-chain cuestan una tx por dueño; Safe agrega firmas off-chain en una sola tx.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
