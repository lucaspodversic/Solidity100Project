# Auditoría — VulnerableToken

| ID | Sev | Hallazgo | Fix |
|---|---|---|---|
| H-04 | Critical | `mint` abierto | `onlyOwner` |
| H-03 | High | `burnFrom` sin allowance | chequear y descontar allowance |
| H-02 | Medium | approve race | `safeApprove` / increase/decrease |
| M-01 | Medium | fee-on-transfer oculto | documentar o eliminar; rompería Uniswap v2 |

PoCs en `test/TokenAudit.t.sol`.
