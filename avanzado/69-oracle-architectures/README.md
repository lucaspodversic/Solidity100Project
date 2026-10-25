# 69 · Comparación de arquitecturas de oráculos — Avanzado

Tres diseños de oráculo detrás de la **misma interfaz** (`IOracle.latest()`), y un consumidor genérico (`PriceConsumer`) que funciona con cualquiera de ellos.

| Contrato | Arquitectura | Inspiración |
|---|---|---|
| `WhitelistOracle.sol` | Reporteros autorizados + mediana + quórum + frescura | Chainlink (simplificado) |
| `StakingOracle.sol` | Reporteros sin permiso con stake, épocas, slashing y unbonding | Tellor / Chronicle / redes de stake |
| `OptimisticOracle.sol` | Propuesta con bond, ventana de disputa y árbitro | UMA Optimistic Oracle |

```bash
forge test -vv   # 18 tests en 4 suites
```

## Tabla de trade-offs

| | Whitelist | Staking | Optimista |
|---|---|---|---|
| **Supuesto de confianza** | Admin honesto + mayoría de reporteros honesta | Mayoría del **stake** de la época honesta | **1 observador honesto** que dispute + árbitro honesto |
| **Latencia** | Baja (cada reporte) | Media (1 época = 1 h) | Alta (liveness = 2 h, o más si hay disputa) |
| **Costo on-chain** | n reportes + mediana en lectura | n reportes + finalize O(n²) | 1 tx (sin disputa) |
| **Permisos** | Cerrado | Abierto | Abierto |
| **Costo de ataque** | Corromper ⌈n/2⌉ entidades conocidas | > 50% del stake, y pierde 10% por época si falla | Superar a todos los disputantes **y** corromper al árbitro |
| **Datos soportados** | Precios numéricos frecuentes | Precios numéricos | **Cualquier afirmación** verificable (resultados, eventos, seguros) |
| **Mejor para** | DeFi de alta frecuencia (préstamos, perps) | Feeds descentralizados de frecuencia media | Datos de baja frecuencia o subjetivos: predicciones, seguros, bridges optimistas |

## Incentivos

- **Whitelist**: reputación y contratos off-chain (los nodos cobran fees y arriesgan su marca). No hay castigo on-chain.
- **Staking**: reportar dentro del 1% de la mediana da recompensas (lo recortado a los demás). Desviarse cuesta un 10% del stake. El unbonding de 2 días impide "mentir y huir".
- **Optimista**: proponer la verdad es gratis (el bond vuelve). Mentir hace perder el bond frente al disputante, que gana el 90% de ese bond. Disputar sin razón tiene el mismo costo para el disputante.

## Ataques y cómo responde cada diseño

| Ataque | Whitelist | Staking | Optimista |
|---|---|---|---|
| Minoría de mentirosos | Mediana: sin efecto (`test_ToleratesMinorityOfLiars`) | Mediana más slashing (`test_FinalizeAndSlash`) | La disputa la corrige (`test_DisputeProposerLoses`) |
| Mayoría de mentirosos | ❌ Compromete el feed | ❌ Compromete el feed y slashea a los honestos (`test_MajorityAttackSucceeds_DocumentedLimit`) | ✅ Basta un disputante |
| Datos viejos | `maxAge` filtra los reportes | El consumidor valida `updatedAt` | El consumidor valida `updatedAt` |
| Spam de reportes | Solo la whitelist | Stake mínimo + `MAX_REPORTERS_PER_EPOCH` | Bond por propuesta |
| Griefing con disputas | n/a | n/a | El disputante arriesga su bond (`test_DisputeProposerWins`) |
| Admin o árbitro malicioso | ❌ Punto central | ✅ No hay admin | ❌ El árbitro decide las disputas (UMA lo descentraliza con votación) |

## Limitaciones conocidas

- `StakingOracle`: si nadie llama a `finalize` antes de que termine el unbonding de un mentiroso, este escapa al slashing. Mitigación: incentivar `finalize` (keeper reward) o extender el unbonding.
- Cada mediana se calcula on-chain con insertion sort (n ≤ 31). Las redes reales agregan off-chain y verifican firmas (OCR).
- El árbitro del optimista es una dirección. En producción sería un DVM, un tribunal tipo Kleros o un multisig con timelock.
