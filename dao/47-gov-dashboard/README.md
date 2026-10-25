# 47 — Governance Dashboard (Intermedio)

Contrato de **lectura** que agrega propuestas, estados, votos y delegaciones para una UI.
Sin front obligatorio: cualquier cliente off-chain llama a `getProposal` / `getProposals` / `votingPower`.

## Estados
| code | meaning |
|---|---|
| 0 | pending |
| 1 | active |
| 2 | succeeded |
| 3 | defeated |
| 4 | executed |

```bash
forge test -vv
```
