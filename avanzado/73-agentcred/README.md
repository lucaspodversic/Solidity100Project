# 73 · AgentCred — Identidad y reputación de agentes IA (ERC-721 + TEE) — Avanzado

Cada agente de IA es un **NFT ERC-721**. La confianza se construye con dos piezas:

1. **Atestación TEE**: prueba criptográfica de que el agente corre un **código aprobado** dentro de un enclave, y de que su clave de firma nunca salió de él.
2. **Reputación anti-sybil**: solo puede calificar quien tenga un **recibo firmado por el agente** desde su enclave.

## Arquitectura

```
┌──────────────── TEE (TDX / SGX / Nitro) ────────────────┐
│ agente IA + agentKey (generada dentro, nunca sale)       │
│ quote = Sign_HW(measurement ‖ hash(agentKey))            │
└───────────────┬───────────────────────────┬──────────────┘
                │ quote                     │ firma Binding(id, owner) y Receipts
                ▼                           ▼
   Verificador de atestaciones         AgentCred.sol (on-chain)
   (off-chain: Intel DCAP / AWS        ├─ attest(): firma del verificador (EIP-712)
    Nitro root CA, collateral,         │            + prueba de posesión de agentKey
    TCB status)                        │            + measurement aprobado por gobernanza
     └─ firma Attestation(id, key,     ├─ isTrusted(id)
        measurement, expiry) ─────────▶├─ rate(): recibo del agente, 1 uso, 1 cliente
                                       └─ verifyAgentSignature(): para otros contratos
```

### ¿Por qué un verificador off-chain?

Verificar un quote DCAP on-chain completo (cadena X.509 de Intel, revocaciones, TCB info) cuesta millones de gas. Proyectos como Automata DCAP lo hacen, pero el patrón más común es delegarlo a un verificador (o comité) que firma un resultado compacto. **Esa es la suposición de confianza principal** y queda documentada como tal: con varios verificadores se puede exigir M de N (extensión sencilla).

### Lo implementado on-chain

| Función | Qué verifica |
|---|---|
| `attest` | dueño del NFT, `expiry` futuro, `measurement ∈ approved`, firma del verificador sobre `Attestation(...)` y firma de `agentKey` sobre `Binding(id, owner)` |
| `isTrusted` | clave presente, no expirada, measurement todavía aprobado |
| `rate` | score 1..5, agente confiable, recibo firmado por `agentKey` para `msg.sender` y no usado |
| `_update` (transfer) | borra la atestación: el comprador debe re-atestar |

## Incentivos

- **Operadores**: un agente atestado y con buena reputación consigue más trabajos (otros protocolos consultan `isTrusted` y `reputation`).
- **Clientes**: califican solo trabajos reales, y su recibo es intransferible.
- **Gobernanza**: puede revocar builds vulnerables al instante (`setMeasurement(m, false)`).

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Atestación falsificada | Firma de un verificador autorizado | `test_RevertWhen_FakeVerifier` |
| Copiar la atestación de otro agente | Binding firmado por `agentKey` | `test_RevertWhen_NoKeyPossession` |
| Correr código no auditado | Allowlist de measurements | `test_RevertWhen_UnapprovedMeasurement` |
| Build con CVE | Revocación que afecta a todos al instante | `test_RevokeMeasurementKillsTrust` |
| Reseñas falsas o sybil | Recibo del agente, por cliente y de un solo uso | `test_RevertWhen_ReceiptReused`, `..StolenByOtherClient`, `..SelfReviewWithoutReceipt` |
| Cambiar el código y conservar la buena reputación | Reset al cambiar la measurement | `test_NewMeasurementResetsReputation` |
| Comprar un agente con buena reputación para estafar | Transfer invalida la atestación; el comprador debe re-atestar | `test_TransferInvalidatesAttestation` |

## Limitaciones conocidas

- **El agente puede emitirse recibos a sí mismo** usando direcciones sybil como "clientes". El recibo prueba que el agente lo emitió, no que el trabajo fue pagado. Mitigación: atar los recibos a pagos on-chain (p. ej. con el marketplace del proyecto 72), o ponderar las reseñas por el stake o la antigüedad del cliente.
- Un agente puede evitar malas calificaciones dejando expirar su atestación (`rate` exige `isTrusted`). Alternativa: permitir calificar durante un período de gracia tras el recibo.
- Confianza en el verificador y en el fabricante del TEE (Intel/AMD/AWS). Hubo ataques de canal lateral históricos contra SGX.
- Las firmas son ECDSA secp256k1. Muchos TEEs usan P-256, y se puede usar la precompile RIP-7212 donde exista.
