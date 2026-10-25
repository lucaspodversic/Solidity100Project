# 58 · Multisig Wallet (Intermedio)

Billetera multifirma **M-de-N**: un grupo de owners propone transacciones y solo se ejecutan cuando juntan `threshold` confirmaciones.

## Estructura

| Ruta | Qué hay |
|---|---|
| `src/MultiSigWallet.sol` | Contrato principal (propuesta, confirmación, revocación, ejecución, administración). |
| `test/MultiSigWallet.t.sol` | 14 tests (incluye fuzz y un atacante de reentrada). |

## Cómo correrlo

```bash
forge build
forge test -vv
```

> Las dependencias (`forge-std`, OpenZeppelin) se comparten en `../lib`.

## Diseño

1. **Propuesta** (`submitTransaction`): cualquier owner propone `(to, value, data)`; el proponente confirma automáticamente.
2. **Confirmación / revocación**: cada owner confirma una vez; puede revocar mientras no se ejecute.
3. **Ejecución** (`executeTransaction`): se recuentan las confirmaciones **de los owners vigentes** y, si alcanzan el umbral, se marca `executed` y se hace la llamada.
4. **Administración** (`addOwner`, `removeOwner`, `changeThreshold`) tiene el modificador `onlyWallet`: solo la propia wallet puede llamarlas, o sea, **requieren pasar por la multifirma**. Ningún owner tiene superpoderes.

## Incentivos

- Ningún owner puede mover fondos solo: hace falta coordinación de `threshold` personas, lo que reparte el riesgo de una clave robada.
- El umbral es configurable: 2/3 para equipos chicos, 4/7 para tesorerías grandes.

## Ataques posibles y defensas

| Ataque | Defensa |
|---|---|
| Reentrada desde el destinatario para ejecutar dos veces | `executed = true` antes de la llamada (CEI) + guarda `nonReentrant`. Test `test_ReentrancyBlocked`. |
| Owner removido cuyas confirmaciones siguen contando | `_validConfirmations` recuenta solo owners vigentes. Test `test_RemovedOwnerConfirmationNotCounted`. |
| Dejar la wallet sin owners o con umbral imposible | `removeOwner` no permite quitar el último y ajusta el umbral; `changeThreshold` valida rangos. |
| Owners duplicados / `address(0)` | Validado en `_addOwner`. |
| DoS por bucle largo | `MAX_OWNERS = 50` acota el recuento. |
| Llamada fallida que "consume" la tx | Si la llamada falla, todo revierte y la tx queda pendiente para reintentar. |

## Limitaciones conocidas

- Si un owner es removido y luego **re-agregado**, sus confirmaciones viejas vuelven a contar (se dejó `ownersNonce` como contador de época para extenderlo).
- No hay firmas off-chain (EIP-712) como en Safe: cada confirmación es una transacción on-chain. Es más simple de auditar a costa de más gas.
