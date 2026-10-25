# 64 · Account Abstraction (ERC-4337) Paymaster + Session Keys (Avanzado)

Implementación didáctica del flujo **ERC-4337**: EntryPoint mock, cuenta inteligente con **session keys** y **Paymaster** que patrocina gas con firma de un backend y presupuesto on-chain.

## Estructura

| Ruta | Qué hay |
|---|---|
| `src/UserOperation.sol` | `UserOperation` (formato v0.6), `IAccount`, `IPaymaster`, `PostOpMode`, librería `ValidationData`. |
| `src/MiniEntryPoint.sol` | EntryPoint simplificado: depósitos, nonce, validación, prefondo, ejecución, `postOp`, reembolso y pago al bundler. Errores `AAxx` iguales a los oficiales. |
| `src/SessionKeyAccount.sol` | Cuenta con owner ECDSA + session keys limitadas por tiempo, destino, selector y valor. |
| `src/SponsorPaymaster.sol` | *Verifying paymaster*: firma off-chain + ventana de validez + presupuesto por cuenta. |
| `test/AA.t.sol` | 15 tests de punta a punta. |

```bash
forge test -vv     # usa via_ir = true (ver foundry.toml)
```

## Flujo

```
Usuario/dApp ──firma UserOp──▶ Bundler ──handleOps──▶ MiniEntryPoint
                                                  │ 1. nonce
                                                  │ 2. account.validateUserOp  (owner o session key)
                                                  │ 3. reserva maxCost del depósito del paymaster
                                                  │ 4. paymaster.validatePaymasterUserOp (firma backend + presupuesto)
                                                  │ 5. call(account, callData)
                                                  │ 6. paymaster.postOp(costo real)
                                                  └ 7. reembolso del sobrante + pago al bundler
```

## Session keys

`signature` de 85 bytes = `[dirección de la session key][firma 65 bytes]`. La cuenta exige:

- `callData` sea `execute(target, value, data)` con `target == session.target`,
- `value <= maxValuePerOp`,
- selector interno permitido (si se restringió),
- no revocada,
- ventana `[validAfter, validUntil]`, que devuelve en `validationData` y **verifica el EntryPoint** (así funciona igual que en el estándar).

Caso de uso: un juego web genera una clave efímera en el navegador y el usuario aprueba una sola vez "esta clave puede llamar `play()` durante 24 h". Cada jugada sale sin popups y sin gas, porque la paga el paymaster.

## Paymaster: incentivos

- La dApp paga el gas para reducir la fricción del onboarding (los usuarios no necesitan ETH).
- El **backend** decide a quién patrocinar (anti-sybil, captcha, KYC liviano) y firma un permiso con vencimiento.
- **On-chain** se impone `budgetPerAccount`: aunque se filtre la clave del backend, cada cuenta solo puede gastar hasta el presupuesto.

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Replay de UserOp | Nonce en el EntryPoint, hash con chainid y EntryPoint | `test_RevertWhen_Replay` |
| Firma falsa de cuenta | `SIG_FAILED` → `AA24` | `test_RevertWhen_BadAccountSig` |
| Firma falsa o vencida del paymaster | `AA34` / `AA32` | `test_RevertWhen_BadPaymasterSig`, `test_RevertWhen_SponsorExpired` |
| Drenar el depósito del paymaster | Presupuesto por cuenta | `test_BudgetExhausted` |
| Session key robada | Destino, selector, valor y tiempo acotados; revocable | 5 tests `SessionKey*` |
| Ejecución que revierte para no pagar gas | La op se cobra igual | `test_ExecutionRevertStillCharged` |
| Llamar `validateUserOp`/`postOp` directo | Solo el EntryPoint | `test_RevertWhen_DirectValidation` |

## Diferencias con el EntryPoint oficial (v0.6/v0.7)

Este mock **no** debe usarse en producción. Le faltan:

- `initCode` (despliegue contrafáctico de cuentas) y agregadores de firmas.
- Nonces con *key* de 192 bits.
- Stake de paymasters y las reglas de simulación ERC-7562 (las aplica el bundler).
- Reintento de `postOp` en modo `postOpReverted`.

En producción, usá el EntryPoint canónico desplegado (`0x0000000071727De22E5E9d8BAf0edAc6f37da032` en v0.7) y las librerías de `eth-infinitism/account-abstraction`.
