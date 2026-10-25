# 24 · Delta-Neutral Vault: cash & carry con funding

**Nivel:** Avanzado. Usa una copia del perpetuo del proyecto 25, en `src/perp/`.

`DeltaNeutralVault` es un ERC-4626 sobre USDC. Con cada depósito **compra ETH spot** y abre
un **short del mismo tamaño** en el perpetuo. La exposición neta a ETH (`delta()`) queda en 0.
La ganancia sale del **funding**: cuando el mercado está cargado de longs, los longs pagan y el
vault, que está short, cobra.

## Diseño

```
capital desplegado C  →  spot N = C/(1+r)  +  margen M = C − N     (r = 50 % → short a 2x)
totalAssets = USDC ocioso + venta del spot en el DEX + (equity del perp − fee de cierre)
```

| Mecanismo | Detalle |
|---|---|
| Reserva | El 10 % de `totalAssets` queda en USDC para retiros chicos |
| Retiro grande | Desarma una **fracción proporcional**: recompra el short, retira margen y vende spot |
| `rebalance()` | Si el ratio margen/notional sale de la banda [25 %, 100 %], cualquiera puede re-armar la posición. El owner puede hacerlo siempre |
| `unwindAll()` | Si el funding/día < `minFundingPerDay`, cualquiera puede desarmar todo. Los depósitos siguientes quedan en USDC hasta que el owner llame a `redeploy()` |
| Slippage | Los swaps y los trades del perp se limitan a ±1 % del precio del oráculo |

### Valuación a precio de salida

`totalAssets` valúa el spot a lo que daría **venderlo** (`dex.quote`) y descuenta la fee de
cerrar el short. Así cada usuario que se va paga su propio costo de desarme.

Con mark-to-market, `previewRedeem` le prometería al último usuario más de lo que se puede
obtener: el test `test_RedeemAll` revertía con `InsufficientLiquidity` hasta que se hizo este
cambio. Además, los costos se les cargarían a los que se quedan. El costo de este enfoque es
que cada depósito "pierde" de entrada ~0,4 % (las fees de entrada y de salida), que se
recupera con el funding.

## Números del test

- 30 000 USDC depositados quedan así: 3 000 de reserva, 18 000 en spot (8,973 ETH después de
  la fee de 0,3 % del DEX), 9 000 de margen y un short de −8,973 ETH. El delta es exactamente 0.
- Con ETH ±20 %, el valor varía < 0,1 %. Solo cambia la fee de salida, que es proporcional al
  precio.
- Con el skew del mercado en ≈ +41 ETH (funding ≈ 0,41 %/día), el vault cobra ≈ **515 USDC en
  7 días**, y la salida a 30 días es de ≈ 32 083 USDC.

## Incentivos

- **Usuarios:** obtienen un rendimiento "de mercado" (el funding) sin exposición al precio.
- **Keepers:** pueden llamar `rebalance` o `unwindAll` sin permiso cuando hace falta. En
  producción se les pagaría un bounty, como en el proyecto 19.
- **El mercado:** el vault está del lado minoritario, así que su short reduce el skew y
  **baja el funding** que cobra. La estrategia se autolimita y su rendimiento cae a medida que
  crece el TVL. El test lo deja ver: el skew baja de 50 a 41.

## Riesgos y ataques

| Riesgo | Mitigación / comentario |
|---|---|
| **Liquidación del short** si ETH sube fuerte (el spot gana, pero está en otra "caja") | Banda de margen y `rebalance` sin permiso. Con margen 50 %, el short aguanta ~+43 % antes de liquidarse (9000 − 8,973·ΔP = 5 %·8,973·(2000+ΔP) → ΔP ≈ 860), y la banda dispara el `rebalance` a ~+30 %. |
| **Funding negativo** | `unwindAll` sin permiso cuando cruza el umbral. Igual se pierde lo que se pagó hasta que alguien actúa. |
| Manipulación del oráculo para forzar un `rebalance` caro | Los swaps tienen tope de slippage contra el oráculo. En producción, TWAP o Chainlink. |
| Sandwich de depósitos y retiros | La valuación conservadora hace que el que entra o sale pague sus fees, así que no hay valor extraíble. |
| Riesgo de contraparte del perp / depeg del USDC | No se cubre: es riesgo de protocolo. |
| Delta imperfecto con el tiempo | El spot es fijo en ETH y el short también, así que el delta se mantiene en 0. Lo que se mueve es el **ratio de margen**. |

## Tests (`test/DeltaNeutralVault.t.sol`, 9)

- Depósito con delta 0 y ratio del 50 %.
- El precio no cambia el valor.
- Se cobra funding.
- Retiro con desarme proporcional.
- `redeem` total.
- `rebalance` cerca de la liquidación, y su rechazo dentro de la banda.
- `unwindAll` cuando el funding se da vuelta, y su rechazo con funding positivo.
- Fuzz de delta neutral.

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
