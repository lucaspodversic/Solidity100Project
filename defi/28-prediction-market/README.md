# 28 · Prediction Market: binario con FPMM y resolución optimista

**Nivel:** Avanzado

`BinaryPredictionMarket` implementa un mercado SÍ/NO sobre una pregunta, por ejemplo
"¿ETH > 5000 USD el 31/12?". Junta tres ideas:

- los **sets completos** de Gnosis Conditional Tokens;
- un **FPMM** (*Fixed Product Market Maker*, el de Omen);
- una **resolución optimista con disputa**, como UMA y Polymarket.

## 1. Sets completos

| Acción | Efecto |
|---|---|
| `split(x)` | x USDC → x YES + x NO (ERC-1155, ids 0 y 1) |
| `merge(x)` | x YES + x NO → x USDC (hasta que el mercado se resuelve) |

**1 YES + 1 NO = 1 USDC** en cualquier escenario. Si P(YES) + P(NO) se aleja de 1, aparece un
arbitraje directo con split o merge. Por eso **el precio de YES es la probabilidad
implícita**.

## 2. FPMM: precios como probabilidades

El pool guarda reservas `y` (YES) y `n` (NO) con `y·n = k`.

```
P(YES) = n / (y + n)
comprar YES con x (neto de fee): y' = k/(n+x), out = y + x − y'   (split de x y salida de YES)
vender YES por r:                n' = n − R,  y' = k/n',  in = y' − y + R   (R = r + fee; merge de R)
```

- **El primer LP fija la probabilidad inicial.** Con p ≥ 0,5, n = amount y
  y = amount·(1−p)/p. Los tokens sobrantes se le devuelven al LP, que queda con exposición a
  ese lado.
- **Fee del 1 %** para los LPs, repartida con un acumulador por share.
- **Números del test:**
  - Con el pool a 50/50 y 10 000 de liquidez, comprar 1000 USDC de YES da 1890,82 YES y sube
    P(YES) a **0,547**.
  - El precio medio pagado (0,529) queda entre el precio previo y el posterior.
  - Una compra minúscula paga exactamente P(YES)/(1 − fee).

### Incentivos

- **Traders:** comprar YES a 0,3 cuando uno cree que la probabilidad real es 0,5 tiene
  esperanza positiva. El mercado agrega información.
- **LPs:** cobran fees, pero asumen *pérdida impermanente* extrema: al resolverse, uno de los
  dos tokens del pool pasa a valer 0. En el test, el LP que puso 10 000 recupera 9683 + 40 de
  fees, después de que los traders "acertaran" contra él. Es el costo de proveer información
  de precio. Polymarket subsidia esto con incentivos de liquidez.

## 3. Resolución optimista

```
Open ──closeTime──► Closed ──propose(+bond)──► Proposed ──(1 día sin disputa)──► Final
                                                   └─ dispute(+bond) ─► Disputed ─ arbitrate ─► Final
```

- El `resolver` propone y deposita un bond.
- Cualquiera puede disputar dentro de la ventana depositando el mismo bond.
- El `arbitrator` decide y quien tenía razón se lleva **los dos bonds**. Mentir cuesta el bond
  y disputar sin razón también.
- Un resultado **INVALID** (pregunta ambigua) paga 0,5 por token de cada lado.

## Seguridad

| Riesgo | Defensa |
|---|---|
| Insolvencia | Todo YES o NO en circulación (incluidas las reservas del pool) nace de un split. Los supplies son siempre iguales y el colateral es igual a los sets, más las fees y los bonds. Fuzz: con trades aleatorios y cualquier resultado, todos cobran y quedan ≤ 5 wei de polvo. |
| Redondeo del AMM | `ceilDiv` sobre la reserva nueva: k nunca baja, así que el pool no pierde por redondeo. |
| Operar con información después del cierre | `buy`, `sell`, `split` y `addLiquidity` solo en `Open`. Lo ideal es que `closeTime` sea **anterior** al evento. |
| Resolver deshonesto | Bond más ventana de disputa más árbitro. El árbitro es una **trust assumption**; en UMA es el voto de los holders del DVM. |
| Front-running / sandwich | `minOut` en `buy` y `maxTokensIn` en `sell`. |
| Reentrancy (hooks de ERC-1155) | `nonReentrant` en todas las funciones externas que mueven fondos. |

## Tests (`test/BinaryPredictionMarket.t.sol`, 12)

- Split/merge.
- Probabilidad inicial y tokens sobrantes.
- La compra mueve la probabilidad.
- El precio marginal es la probabilidad.
- El ida y vuelta cuesta solo las fees.
- Slippage.
- Resolución YES con redeem.
- Disputa y arbitraje.
- Ventanas y fases.
- INVALID paga 0,5.
- El LP cobra fees y hace redeem.
- **Fuzz de solvencia.**

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
