# 04 · Limit Order Book DEX

**Nivel:** Avanzado

Libro de órdenes límite totalmente on-chain para un par BASE/QUOTE, con matching por
**prioridad precio-tiempo**, ejecuciones parciales, órdenes IOC/market, cancelación y
liquidación por patrón *pull*.

## Contrato

`src/OrderBookDEX.sol`

| Función | Descripción |
|---|---|
| `placeLimitOrder(isBuy, price, amount, maxMatches, postRemainder)` | Cruza contra el libro y deja el remanente en reposo (o lo descarta si `postRemainder=false`, modo IOC/market). |
| `cancel(id)` | Cancela y acredita lo no ejecutado. |
| `withdraw(token)` | Retira saldos acreditados. |
| `bestBid / bestAsk / depthAt / bidLevels / askLevels` | Lecturas del libro. |

## Diseño

- **Niveles de precio:** cola FIFO doblemente enlazada por precio → prioridad temporal y
  cancelación O(1).
- **Precios activos:** arreglos ordenados con el **mejor precio al final** (bids ascendentes, asks
  descendentes) para que consumir el mejor nivel sea un `pop`.
- **Precio de ejecución:** el del **maker**; el taker se queda con la mejora de precio.
- **Escrow:** las ventas en reposo bloquean BASE; las compras bloquean QUOTE redondeado hacia
  arriba. Al completarse una compra, el polvo de redondeo se devuelve al maker.
- **Comisión taker:** 0,1 % (configurable ≤ 1 %) sobre el monto en QUOTE.

## Incentivos económicos

Los makers proveen liquidez gratis (0 % de comisión) a cambio de esperar y del riesgo de
**selección adversa** (ser ejecutados justo cuando el precio se mueve en su contra). Los takers
pagan por inmediatez. Esto premia a los market makers que cotizan spreads ajustados.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| DoS por gas (miles de órdenes diminutas en el mejor nivel) | `maxMatches` ≤ 50 por llamada; rechazo de órdenes "polvo" (`DustOrder`). |
| Maker con token bloqueado que hace revertir el matching | Patrón pull: el matching solo acredita `claimable`; nadie recibe transferencias durante el cruce. |
| Reentrancia (tokens con hooks) | `ReentrancyGuard` + todas las transferencias al final. |
| Extracción por redondeo | Escrow hacia arriba, pagos hacia abajo; fuzz de conservación verifica que el contrato queda en 0. |
| Front-running / MEV | Inherente a un CLOB on-chain en una L1 pública; mitigable con L2 con secuenciador justo o batch auctions (documentado). |
| Cancelar órdenes ajenas | Chequeo de `owner`. |

## Limitaciones

Inserción de nuevos niveles O(n) en cantidad de niveles; en producción se usan árboles
rojo-negro o bitmaps de ticks. Sin órdenes stop ni expiración.

## Tests (13)

Construcción del libro, ejecución al precio maker con fee, parciales de maker y de taker, FIFO,
barrido de varios niveles, venta contra bid con escrow, cancelación con reembolso, permisos,
cancelación en medio de la cola, tope de matches, órdenes polvo y fuzz de conservación de fondos.

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
