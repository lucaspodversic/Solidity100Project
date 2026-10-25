# 71 · Tokenized Real Estate (NFTs + DAO) — Avanzado

Inmueble tokenizado: la **escritura es un NFT** custodiado por una **DAO**, y la propiedad económica se reparte en **fracciones ERC-20 con votos** que cobran renta pro-rata y deciden la gestión y la venta.

| Contrato | Rol |
|---|---|
| `PropertyRegistry` | ERC-721 de escrituras (hash del documento legal, URI y tasación) y lista KYC. Lo opera un registrador legal. |
| `PropertyShares` | ERC-20 + **ERC20Votes**: fracciones con transferencias solo entre wallets con KYC, renta en ETH con acumulador y auto-delegación. |
| `PropertyDAO` | Custodia el NFT. Maneja propuestas, votación con snapshot, quórum, timelock, ofertas de compra en escrow y venta. |

## Flujo

1. El registrador verifica la escritura (off-chain: SPV o fideicomiso) y emite el NFT **a la DAO**.
2. Se despliegan las fracciones (1000 CASA1 = 100% del inmueble) para los inversores con KYC.
3. El inquilino paga renta con `depositRent()` y cada holder cobra con `withdrawRent()`.
4. Gastos y decisiones pasan por propuesta → voto (5 días) → `queue` → timelock (2 días) → `execute`.
5. **Venta**: un comprador deja ETH con `makeOffer()`. Si una propuesta ejecuta `acceptOffer(id)`, el NFT pasa al comprador y el ETH se reparte entre holders como dividendo.

## Incentivos

- **Inversores**: acceso fraccionado al real estate, liquidez secundaria (entre KYC) y renta automática.
- **Comprador**: puede retirar su oferta en cualquier momento antes de que se acepte.
- **Minoritarios**: el timelock les da tiempo de salir si no están de acuerdo con una decisión.

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Comprar votos (o flash loan) después de una propuesta | `getPastVotes` en el snapshot `block.number-1` | `test_SnapshotPreventsLateVoteBuying` |
| Spam de propuestas | Umbral del 1% del supply | `test_RevertWhen_BelowThreshold` |
| Minoría decide sola | Quórum del 20% y mayoría | `test_QuorumNotReached` |
| Ejecutar sin aviso | Timelock de 2 días | `test_RevertWhen_ExecuteBeforeTimelock` |
| Vender el NFT sin votación | `acceptOffer` es `onlySelf` | `test_RevertWhen_AcceptOfferDirectly` |
| Gastar el ETH de ofertas | `escrowed` separado, `pay` no lo toca | `test_PayExpenseButNotFromEscrow` |
| Comprar fracciones para cobrar renta pasada | Correcciones del acumulador en `_update` | `test_TransferDoesNotStealPastRent` |
| Fracciones a wallets sancionadas | KYC en cada transferencia | `test_RevertWhen_TransferToNonKyc` |
| Reentrancy en retiros | `nonReentrant` + CEI | — |

Redondeo: el acumulador usa `2^128` de precisión y siempre redondea a favor del contrato (±1 wei). Lo verifica `testFuzz_RentConservation`.

## Limitaciones

- **El NFT no es el título legal**: el vínculo jurídico (SPV, fideicomiso, registro de la propiedad) es off-chain y depende del registrador. El NFT solo representa ese derecho.
- El registrador es centralizado: puede quitar el KYC y congelar fracciones (requisito regulatorio, pero es un poder fuerte).
- Al vender, las fracciones siguen existiendo (solo cobran el producto de la venta). Una versión completa las quemaría o redimiría.
- Gobernanza simple (sin delegación por firma ni votos de abstención). Para producción conviene OZ `Governor` + `TimelockController`.
