# 92. IPFS Hash Storage

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Anclar archivos de IPFS on-chain guardando su CID (como string) o solo el digest sha256 de 32 bytes de un CIDv0.

## Archivos
- `src/IPFSRegistry.sol` — `store`, `update`, `uri`, `documentsOf`, `storeDigest`, `multihashOf`.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. Subir el archivo a IPFS (p. ej. `ipfs add archivo`) y obtener el CID.
2. `store(cid)`; `uri(id)` devuelve `ipfs://<cid>`.
3. Variante compacta: `storeDigest(digest)`; el front arma `base58(0x1220 || digest)`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- El contenido en IPFS solo persiste si alguien lo *pinnea* (Pinata, web3.storage, nodo propio).
- No subas datos privados: IPFS es público.
- El historial de versiones queda en eventos `DocumentUpdated`.

## Consideraciones de gas
- String de ~46-59 bytes = 2-3 slots; digest = 1 slot (`test_GasStringVsDigest`).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
