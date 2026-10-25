# 63 · Smart Contract Wallet (Intermedio)

Billetera inteligente con autenticación por **`msg.sender`**, operadores con límites, ejecución por lotes, recuperación social con retraso y firmas **EIP-1271**.

## Estructura

| Ruta | Qué hay |
|---|---|
| `src/SmartWallet.sol` | La wallet completa. |
| `test/SmartWallet.t.sol` | 11 tests (phishing con `tx.origin`, límites, lotes, recuperación, EIP-1271, fuzz). |

```bash
forge test -vv
```

## Roles

| Rol | Puede |
|---|---|
| **Owner** | Todo: ejecutar, lotes, configurar operadores, guardianes y transferir ownership. |
| **Operador** | Ejecutar solo hacia destinos en su lista blanca, con un **límite diario de ETH**. Nunca puede llamar a la propia wallet. |
| **Guardián** | Proponer y aprobar una recuperación (cambio de owner) que se aplica después de 2 días. |

## Por qué `msg.sender` y no `tx.origin`

Si la wallet autorizara con `tx.origin == owner`, cualquier contrato malicioso que el owner llamara (un "airdrop" falso, por ejemplo) podría llamar a la wallet y vaciarla, porque `tx.origin` seguiría siendo el owner. El test `test_TxOriginPhishingFails` reproduce ese ataque y muestra que falla.

## Recuperación social

1. Un guardián llama `proposeRecovery(nuevoOwner)`, lo que abre una **ronda** nueva con su aprobación.
2. Otros guardianes aprueban hasta llegar a `guardianThreshold`.
3. Tras `RECOVERY_DELAY` (2 días), **cualquiera** puede ejecutar `executeRecovery`.
4. Mientras tanto, si el owner todavía tiene su clave, puede `cancelRecovery`. Esto protege contra guardianes que se coludan.

Cada propuesta nueva abre otra ronda y las aprobaciones viejas no se arrastran (`test_NewProposalResetsApprovals`).

## EIP-1271

`isValidSignature(hash, sig)` devuelve `0x1626ba7e` si el **owner actual** firmó `keccak256(hash, wallet, chainid)`. Envolver el hash evita el *replay* de la misma firma en otra wallet del mismo owner o en otra cadena.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Phishing con `tx.origin` | Solo se usa `msg.sender`. |
| Operador comprometido vacía la wallet | Límite diario + lista blanca. Fuzz `testFuzz_OperatorNeverExceedsLimit`. |
| Operador que se auto-asciende llamando `transferOwnership` vía `execute` | Prohibido llamar a la propia wallet. |
| Guardianes coludidos | Retraso de 2 días + cancelación por el owner. |
| Replay de firmas EIP-1271 | Hash envuelto con la dirección y el chainid. |
| Lote parcialmente ejecutado | Es atómico: si una llamada falla, revierte todo el lote. |

## Limitaciones

- El límite diario solo cuenta ETH. Los ERC20 transferidos por `data` no se limitan, por eso la lista blanca de destinos es la defensa principal para tokens.
- Para usar la wallet sin ETH en la EOA (gas patrocinado) ver el proyecto 64 (ERC-4337).
