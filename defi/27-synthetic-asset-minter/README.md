# 27 · Synthetic Asset Minter: CDPs con stability fee

**Nivel:** Intermedio-avanzado

`SynthMinter` permite depositar **WETH** y acuñar **sXAU**, un oro sintético que sigue el
precio del oráculo. Es el modelo de CDP de MakerDAO, Synthetix v1 y Mirror.
`SyntheticAsset` es un ERC-20 con permit que solo el minter puede emitir o quemar.

## Parámetros

| Parámetro | Valor | Para qué |
|---|---|---|
| MCR | 150 % | Mínimo para acuñar o retirar |
| Ratio de liquidación | 120 % | Por debajo, cualquiera liquida |
| Penalidad | 10 % | Bonus del liquidador |
| Close factor | 50 % | Máximo repago por liquidación |
| Stability fee | 5 %/año | Interés sobre la deuda |
| Debt ceiling | configurable | Tope de exposición al oráculo |

`setRisk` exige que **la penalidad sea menor que el colchón (ratio de liquidación − 100 %)**.
Si no fuera así, cada liquidación sacaría más colateral del que existe y generaría deuda
incobrable.

## Mecanismos de estabilidad (el peg)

1. **Sobrecolateralización:** cada sXAU está respaldado por al menos 1,5 veces su valor en
   WETH.
2. **Arbitraje de liquidación:** para liquidar hay que **comprar sXAU** y quemarlo. Cuando hay
   riesgo, eso genera demanda y empuja el precio de mercado hacia el del oráculo.
3. **Stability fee como política monetaria:**
   - Si sXAU cotiza por **debajo** del oráculo, se **sube** la fee. La deuda se encarece, los
     minters recompran y queman, la oferta cae y el precio sube.
   - Si cotiza por **encima**, se **baja** la fee: acuñar es más barato y la oferta sube.
4. **Índice acumulador** (`rateIndex`, como el `rate` de Maker):
   - Cada vault guarda su `normDebt` y la deuda real es `normDebt · rateIndex`.
   - El costo de `accrue()` es O(1) para todos los vaults.
   - El interés nuevo se acuña al **tesoro**, así que la oferta total de sXAU coincide
     siempre con la deuda total. Lo verifica un fuzz.
   - `setStabilityFee` llama a `accrue()` antes de cambiar la tasa, para que lo devengado
     hasta ese momento se cobre con la tasa vieja.

## Liquidación y deuda incobrable

```
seized (WETH) = repay · P_sXAU · (1 + penalidad) / P_WETH
```

- **Ejemplo del test:** con WETH a 1500, el CR baja a 112,5 %. El liquidador repaga 0,8 sXAU
  (2000 USD) y se lleva 1,4667 WETH (2200 USD). El CR queda en ~115 %, todavía liquidable.
  Es el conocido efecto de que la penalidad *empeora* el ratio. Por eso existe un close
  factor y pueden hacer falta varias rondas.
- **Colateral insuficiente:** con WETH a 500 el liquidador se lleva todo y repaga en
  proporción. La deuda restante (≈1,05 sXAU) pasa a `badDebt`. Cualquier tenedor de sXAU, en
  la práctica el tesoro con lo que juntó de fees, puede cancelarla con `healBadDebt`.

## Riesgos y ataques

| Riesgo | Comentario |
|---|---|
| **Oráculo del sintético** | Es el riesgo n.º 1: Mirror y Synthetix sufrieron *front-running* del oráculo y precios fuera de horario de mercado. Las mitigaciones son Chainlink con heartbeat, *market closed flags* y fees dinámicas. Acá el mock tiene solo `maxAge`. |
| Suba del subyacente sintético | Si el oro sube, la deuda vale más y los vaults se liquidan aunque el WETH no se mueva (test incluido). |
| Liquidaciones en cascada | El close factor y el colchón de 30 % entre el MCR y el ratio de liquidación las limitan. |
| Redondeo | La deuda normalizada se redondea **hacia arriba** al acuñar, `debtOf` también redondea hacia arriba y el repago parcial hacia abajo, siempre a favor del sistema. |
| Reentrancy | `nonReentrant`. WETH y sXAU no tienen hooks. |

## Tests (`test/SynthMinter.t.sol`, 11)

- MCR y precio de liquidación.
- Retiro bloqueado.
- La suba del sintético vuelve liquidable el vault.
- Liquidación parcial con penalidad.
- Stability fee al tesoro, con oferta = deuda.
- Cambio de fee que primero devenga lo anterior.
- Deuda incobrable y `heal`.
- Debt ceiling.
- `onlyMinter` en el token.
- Validación de los parámetros de riesgo.
- Fuzz de mint + accrue.

## Cómo compilar y testear

Requisitos: [Foundry](https://book.getfoundry.sh/) (`curl -L https://foundry.paradigm.xyz | bash && foundryup`).

Las dependencias (`forge-std` y `openzeppelin-contracts` v5.1.0) están vendorizadas en `../lib`
(compartidas por todos los proyectos del lote DeFi). Desde esta carpeta:

```bash
forge build          # compila
forge test -vv       # corre todos los tests (unitarios + fuzz)
forge test --gas-report
```

Si querés usar la carpeta de forma aislada (fuera de `defi/`), instalá las dependencias localmente
y ajustá `libs`/`remappings` en `foundry.toml` a `lib/`:

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
```

> Código educativo, no auditado. No lo uses en mainnet con fondos reales sin una auditoría profesional.
