# 26 · Options Protocol: calls y puts europeas con colateral completo

**Nivel:** Intermedio-avanzado

`OptionsMarket` permite crear **series** (tipo, strike, vencimiento), cada una como un id
ERC-1155. Las opciones son **europeas** (solo se ejercen al vencimiento) y se **liquidan en
efectivo** contra el precio del oráculo. El modelo es el de Opyn v1: cada opción está
**totalmente colateralizada**.

## Flujo

```
createSeries(call|put, K, T)        ← sin permisos; id = keccak(tipo, K, T)
write(id, n)                        ← el writer deposita colateral y recibe n tokens
  (vende los tokens por una prima: AMM/OTC, fuera de alcance)
closeWrite(id, n)                   ← antes de T: recompra y quema, y recupera colateral
── T ──
settle(id)                          ← cualquiera, dentro de 1 h después de T, con el oráculo
settleManual(id, S)                 ← owner, recién 1 día después de T si nadie liquidó
exercise(id, n)                     ← el holder cobra el payoff
redeemWriter(id)                    ← el writer recupera colateral − payoff
```

| | Colateral por opción | Payoff del holder | Lo que vuelve al writer |
|---|---|---|---|
| **Call** (cubierta) | 1 WETH | max(S−K, 0)/S WETH | min(K/S, 1) WETH |
| **Put** (cash-secured) | K USDC | max(K−S, 0) USDC | min(K, S) USDC |

El payoff de la call se paga en el **subyacente**: es su valor en USD dividido por S. Así,
el colateral en WETH alcanza siempre, sin importar cuánto suba el precio.

## Incentivos

- **Writer:** cobra la prima por adelantado a cambio de ceder el *upside* (call) o de
  comprometerse a "comprar barato" (put). Es el *covered call* o *cash-secured put* clásico.
- **Holder:** paga la prima y obtiene exposición asimétrica, con la pérdida limitada a esa
  prima.
- **Keeper de settlement:** el incentivo implícito es que holders y writers necesitan cobrar.
  En producción se paga un bounty o se automatiza con Chainlink Automation.

## Seguridad

| Riesgo | Defensa |
|---|---|
| **Insolvencia** | Colateral completo, así que no hay liquidaciones ni deuda incobrable. `holderPayoff` y `writerPayout` se calculan **por separado y redondeando hacia abajo**: los holders y los writers juntos nunca cobran más que el colateral. Lo verifica un fuzz con 2 writers, cualquier precio y tanto calls como puts. |
| Elegir el precio de settlement *a posteriori* | `settle` solo funciona dentro de `SETTLE_WINDOW` (1 h) después del vencimiento. Fuera de ese plazo queda el respaldo manual del owner, que es una **trust assumption** documentada. Lo ideal es leer el round histórico de Chainlink en T o usar un TWAP. |
| Manipular el oráculo al vencimiento | Es el ataque clásico a las opciones on-chain y es una limitación de este mock. La mitigación es un TWAP o Chainlink, y que el settlement no dependa de un spot instantáneo. |
| Robar colateral con `closeWrite` | Exige **quemar** los tokens (tenerlos) **y** haber lanzado esa cantidad (`written`). Un holder que no lanzó no puede cerrar. |
| Polvo por redondeo en el ida y vuelta | `write` redondea el colateral hacia arriba y `closeWrite` lo devuelve redondeando hacia abajo. |
| Operar una serie vencida | `write` y `closeWrite` revierten con `Expired` a partir de T. |
| Reentrancy (callbacks de ERC-1155 en `_mint` y en las transferencias) | `nonReentrant` en todas las funciones que mueven fondos, y el estado se actualiza antes de transferir. |

## Limitaciones

- No incluye un AMM de primas ni Black-Scholes. `intrinsicValue` es solo de referencia.
  Calcular la prima requiere volatilidad implícita, que es el problema que resuelven Lyra y
  Premia.
- Solo hay un subyacente (ETH) por deploy y no existe el margen parcial (*naked writing*).

## Tests (`test/OptionsMarket.t.sol`, 10)

- Call ITM y OTM, put ITM y OTM (con el contrato que queda en 0).
- `closeWrite`, y las protecciones de `closeWrite`.
- Reglas de tiempo: no se puede liquidar antes de T, no se puede lanzar después de T,
  `WindowClosed`, el manual con delay y `onlyOwner`, y el doble settlement.
- Validación de series.
- Valor intrínseco y paridad put-call al vencimiento (C − P = S − K).
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
