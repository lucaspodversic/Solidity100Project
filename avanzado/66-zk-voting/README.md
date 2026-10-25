# 66 · Votación ZK (Groth16) — Avanzado

Votación **anónima y "una persona, un voto"** con pruebas de conocimiento cero, al estilo Semaphore.

| Ruta | Qué hay |
|---|---|
| `src/Groth16Verifier.sol` | Verificador Groth16 **real** y genérico sobre BN254, con los precompilados `ecAdd` (0x06), `ecMul` (0x07) y `ecPairing` (0x08). |
| `src/ZkVoting.sol` | Propuestas, snapshot de la raíz Merkle, nullifiers y conteo. |
| `circuits/vote.circom` | Circuito de referencia (documentación; **no se compila** en este repo). |
| `test/ZkVoting.t.sol` | 15 tests, incluido un fuzz de pruebas válidas sobre los pairings reales. |

```bash
forge test -vv
```

## Enfoque elegido y por qué

La consigna pedía un ejemplo de verificador Groth16 o un circuito Noir mock que compile y testee la lógica de verificación. Elegí un **verificador Groth16 real** (el mismo algoritmo que genera snarkjs) y lo testeo con un **trusted setup de juguete**:

- Todos los puntos de la VK son múltiplos conocidos de los generadores: `α = 7·G1`, `IC = [11,13,17,19,23]·G1`, `β = γ = δ = G2`.
- Con `B = G2`, la ecuación `e(A,B) = e(α,β)·e(vk_x,γ)·e(C,δ)` se reduce a `a = α + vk_x + c (mod R)`.
- El "prover" del test elige `a`, despeja `c` y arma `A = a·G1` y `C = c·G1`.

Así **los tests ejercitan los pairings reales del EVM** (cálculo de `vk_x`, negación de A, codificación Fp2 de G2 según EIP-197, chequeo de campo) sin depender de circom, snarkjs ni Node.

> ⚠️ Una VK de juguete es **totalmente insegura**: quien conoce el trapdoor falsifica pruebas. En producción la VK sale de una ceremonia (Powers of Tau + fase 2 por circuito) y se usa el `Verifier.sol` exportado por snarkjs.

## Pipeline off-chain (producción)

1. Cada votante genera `secret` y `nullifierKey`, y publica `commitment = Poseidon(secret, nullifierKey)`.
2. El registrador (KYC o lista de miembros) arma un árbol Merkle Poseidon de commitments y llama `setRoot(root)`.
3. `createProposal` toma un **snapshot** de la raíz.
4. El votante calcula `nullifierHash = Poseidon(nullifierKey, proposalId)` y genera la prueba con `circuits/vote.circom`:
   ```bash
   circom vote.circom --r1cs --wasm
   snarkjs groth16 setup vote.r1cs pot20_final.ptau vote_0000.zkey
   snarkjs zkey contribute ... && snarkjs zkey export solidityverifier vote.zkey Verifier.sol
   snarkjs groth16 fullprove input.json vote.wasm vote.zkey proof.json public.json
   ```
5. Un **relayer** envía `vote(...)` para que tampoco se vea la dirección que paga el gas.

## Inputs públicos (el orden importa)

`[root, nullifierHash, proposalId, option]`. El contrato los **arma él mismo** con la raíz de la propuesta, así que el usuario no puede inyectar otra raíz ni otra propuesta.

## Seguridad y ataques

| Ataque | Defensa | Test |
|---|---|---|
| Votar dos veces | `nullifierHash` único por (persona, propuesta) | `test_RevertWhen_DoubleVote` |
| Relayer cambia el voto | `option` es input público: la prueba deja de ser válida | `test_RevertWhen_ChangingOptionOfSomeoneElsesProof` |
| Reusar una prueba en otra propuesta | `proposalId` es input público | `test_RevertWhen_ProofForOtherProposal` |
| Maleabilidad `x` vs `x+R` | `input < R` obligatorio | `test_RevertWhen_InputNotInField` |
| Puntos fuera de la curva | El precompilado falla y se devuelve `false` | `test_VerifierRejectsPointNotOnCurve` |
| Sumar votantes durante la votación | Snapshot de la raíz por propuesta | `test_RootSnapshot` |
| Desanonimizar por gas | Relayer | (diseño) |

## Limitaciones y confianza

- **Registrador centralizado**: decide quién es elegible (puede agregar sybils). Mitigaciones posibles: multisig o DAO como owner, o raíz basada en un NFT o credencial.
- La privacidad depende de un conjunto de anonimato grande: con 3 votantes, el anonimato es débil.
- No hay protección anti-coerción (MACI resuelve eso con claves cambiables y un coordinador).
- El conteo es público en tiempo real. Para ocultarlo hasta el final se necesitaría cifrado homomórfico o commit-reveal.
