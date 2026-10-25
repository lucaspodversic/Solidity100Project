# 72 · AI Auditor Marketplace + certificados soulbound — Avanzado

Mercado donde **agentes de IA** (operados off-chain) compiten por auditar contratos. El cliente paga con escrow, elige el mejor informe y recibe un **certificado NFT soulbound** (ERC-5192) atado al **codehash** del contrato auditado.

| Contrato | Rol |
|---|---|
| `AuditMarketplace` | Registro de agentes con stake, trabajos, commit-reveal, adjudicación, reparto, slashing y pagos pull. |
| `AuditCertificate` | ERC-721 no transferible (ERC-5192). `isValid(id)` comprueba que no esté revocado y que el codehash siga siendo el mismo. |

## Flujo

```
Operador ──registerAgent(modelHash, endpoint) + ≥1 ETH stake
Cliente  ──postJob(target) + recompensa      (se fija target.codehash)
Agentes  ──commit(keccak(job, agent, reportHash, salt))      [commitWindow]
Agentes  ──reveal(reportHash, salt)                         [revealWindow]
Cliente  ──award(agentId) → 95% al agente, 5% fee, SBT al cliente  [reviewWindow]
        └─ si no decide: settleExpired → reparto entre los que revelaron
Árbitro  ──revokeAndSlash(cert) si aparece un exploit → 50% del stake al cliente
```

### ¿Qué es on-chain y qué off-chain?

- **Off-chain (documentado):** el agente descarga el código verificado del `target`, corre su pipeline (LLM + Slither/Echidna, por ejemplo), sube el informe a IPFS y obtiene `reportHash`. `modelHash` identifica pesos y versión del prompt, para auditar al auditor.
- **On-chain (implementado):** compromisos, plazos, dinero, reputación, garantías y certificados.

## Incentivos

- **Agentes**: cobran si su informe es el mejor y arriesgan su stake si certifican código explotable. La reputación es pública (`completed − 3×slashed`).
- **Cliente**: obtiene un certificado verificable on-chain. No puede ver los informes y luego no pagar (*free-riding*): con reveals no hay `cancel`, y si no decide, se reparte igual.
- **Protocolo**: cobra 5% de fee.

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Copiar el informe de otro agente | Commit-reveal con `agentId` y `salt` | `test_RevertWhen_RevealWrongReport` |
| Cliente lee informes y se va sin pagar | Sin `cancel` tras reveals y reparto automático | `test_RevertWhen_ClientCancelsAfterReveals`, `test_SplitWhenClientIgnores` |
| Vender o comprar certificados | Soulbound: `_update` revierte transferencias | `test_RevertWhen_TransferCertificate` |
| Certificar v1 y desplegar v2 maliciosa | `isValid` compara el codehash actual | `test_CertificateInvalidWhenCodeChanges` |
| Agente negligente | Slashing del 50% y pérdida de reputación; con stake < mínimo no compite | `test_RevokeAndSlash` |
| Escapar del slashing retirando stake | Unbonding de 14 días, sin trabajos nuevos en ese tiempo | `test_UnbondFlow` |
| Reentrancy en pagos | Pull payments (`credit` + `claim`) y `nonReentrant` | — |

## Limitaciones

- **El árbitro está centralizado** (Ownable). En producción: DAO, Kleros o UMA para decidir si un exploit "debía" ser detectado.
- Pasado el unbonding no queda stake que slashear: el seguro dura 14 días. Una versión real exigiría stake bloqueado por certificado durante N meses.
- Proxies: el codehash del proxy no cambia al actualizar la implementación. Habría que certificar la implementación (slot EIP-1967).
- `settleExpired` itera los reveals. Se podría limitar la cantidad de agentes por trabajo para acotar el gas.
- No se verifica el contenido del informe: solo se compromete su hash.
