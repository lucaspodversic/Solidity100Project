# 93. Merkle Tree Whitelist

**Nivel:** Intermedio · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Whitelist/airdrop eficiente con árbol de Merkle: una raíz de 32 bytes on-chain y pruebas de log2(N) hashes. El test construye el árbol y genera las pruebas en Solidity.

## Archivos
- `src/MerkleAirdrop.sol` — ERC20 con `claim(index, account, amount, proof)`, `MerkleProof` y `BitMaps` de OpenZeppelin.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
Off-chain (JS), el árbol compatible se genera con el StandardMerkleTree de OpenZeppelin (`@openzeppelin/merkle-tree`) usando la codificación `["uint256","address","uint256"]`. En el test se reproduce el mismo algoritmo.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Doble hash de la hoja para evitar ataques de segunda preimagen.
- `abi.encode` (no `encodePacked`).
- BitMap para impedir reclamos dobles.
- La raíz es inmutable: un error en la lista requiere redeploy.

## Consideraciones de gas
- Guardar 1 raíz vs N direcciones (N × 22k gas); `BitMaps` marca 256 reclamos por slot.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
