# 74 · LeaseNFT — NFT + vault de alquileres — Avanzado

Alquiler on-chain de activos tokenizados (departamentos, autos, maquinaria, licencias). Separa **propiedad** de **uso** con **ERC-4907**, y el dinero (depósito y rentas en una stablecoin ERC-20) vive en un **vault** con reglas automáticas.

| Contrato | Rol |
|---|---|
| `LeaseNFT` | ERC-721 + ERC-4907 (`userOf`, `userExpires`). Solo el vault asigna usuarios. |
| `RentVault` | Ofertas, aceptación, prepago, liberación de renta, desalojo, fin de contrato, daños, disputa y arbitraje. |
| `MockUSD` | Stablecoin de prueba. |

## Ciclo de vida

```
offer ─▶ accept (depósito + mes 1) ─▶ Active ──payRent(n)──▶ extiende userExpires
                                       │  claimRent(): libera períodos pagados que ya empezaron
                                       ├─ sin pago + gracia ─▶ evict ─▶ Closed
                                       └─ término cumplido ─▶ end ─▶ Ended
                                                                   ├─ claimDamage(≤ depósito, evidencia)
                                                                   ├─ dispute (inquilino) ─▶ resolve (árbitro) ─▶ Closed
                                                                   └─ settle (tras 6 días) ─▶ Closed
```

**La idea clave:** `userExpires = start + períodosPagados × período + gracia`. Si el inquilino no paga, **el derecho de uso vence solo**. Una cerradura inteligente o una API que consulta `userOf` corta el acceso sin que nadie intervenga ni pueda abusar.

## Incentivos

- **Dueño**: cobra puntual (renta anticipada), con depósito como garantía. Puede **vender el NFT con el contrato adentro**: la renta va al `ownerOf` actual (tokenización de ingresos).
- **Inquilino**: su derecho de uso no lo puede revocar el dueño mientras pague (solo el vault asigna usuarios). El depósito vuelve automáticamente y los reclamos de daños se pueden disputar.
- **Árbitro**: solo interviene en disputas y nunca puede asignar más que el depósito.

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Dueño echa a un inquilino al día | `setUser` solo del vault | `test_RevertWhen_NonVaultSetsUser` |
| Dueño cobra renta futura por adelantado | `claimable` solo libera períodos ya empezados | `test_ClaimOnlyStartedPeriods` |
| Inquilino usa sin pagar | El uso expira solo; `evict` tras la gracia | `test_UsageExpiresWithoutPayment`, `test_Evict` |
| Reclamo de daños abusivo | Tope = depósito, ventana de 3 días y disputa con árbitro | `test_RevertWhen_DamageAboveDeposit`, `test_DamageDisputedArbiterResolves` |
| Tercero acepta la oferta | Solo el `tenant` designado | `test_RevertWhen_OtherAccepts` |
| El vault paga de más | Invariante de conservación (fuzz) | `testFuzz_Conservation` |
| Tokens raros (sin bool) | `SafeERC20` | — |

## Limitaciones

- El NFT no hace cumplir nada en el mundo físico: hace falta un dispositivo o servicio que consulte `userOf` (cerradura IoT, backend). El desalojo legal sigue siendo off-chain.
- Sin rescisión anticipada por parte del inquilino (se podría agregar con una penalidad).
- La penalidad por mora es fija (1 período). El árbitro es una dirección y podría ser una DAO o Kleros.
- Un contrato activo por NFT. Tokens fee-on-transfer no soportados.
