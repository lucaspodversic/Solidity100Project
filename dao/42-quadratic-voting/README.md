# 42 — Quadratic Voting DAO (Avanzado)

Voto con peso `sqrt(créditos)` y presupuesto fijo por propuesta. Delegación simple del derecho a votar.

La concavidad de sqrt hace que fragmentar créditos entre muchos votos (o muchos votantes) rinda más peso total que concentrarlos — espíritu del quadratic voting.

```bash
forge test -vv
```
