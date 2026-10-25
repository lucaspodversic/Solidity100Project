# 03 · Multi-hop Router

**Nivel:** Avanzado

Router que modela los pools como un grafo (tokens = nodos, pools = aristas) y busca la secuencia
de pools que **maximiza la salida** para un monto dado, y luego la ejecuta de forma atómica.

## Contratos

| Archivo | Rol |
|---|---|
| `src/SimplePool.sol` | Pool x·y=k con comisión configurable (bps). |
| `src/MultiHopRouter.sol` | Registro de pools, `findBestRoute` (DFS acotado), `quotePath`, `swapAlongPath`, `swapBest`. |

## Diseño

- **Búsqueda:** DFS con backtracking, profundidad máxima `MAX_HOPS = 4`, sin reutilizar pools en
  una misma ruta. Como la salida de x·y=k depende del monto, se simula el monto real en cada salto
  (no basta con comparar precios spot: el impacto de precio cambia la ruta óptima).
- **Ejecución:** el router recibe los intermedios y el último salto paga directo al usuario. El
  `minOut` se valida **solo sobre el resultado final**, que es lo que le importa al usuario.
- **Patrón recomendado:** calcular la ruta off-chain con `eth_call` a `findBestRoute` (gratis) y
  enviar `swapAlongPath`. `swapBest` busca on-chain: cómodo pero caro.

## Incentivos económicos

Rutear por pools profundos reduce impacto de precio aunque se pague más de una comisión; el router
captura esa diferencia para el usuario. Para los LP, el ruteo distribuye flujo hacia los pools más
líquidos, reforzando la profundidad donde ya existe (efecto red).

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Pool malicioso con cotizaciones falsas o reentrancia | Solo el owner registra pools; `swapAlongPath` rechaza pools no registrados. |
| DoS por explosión combinatoria | `MAX_POOLS = 32`, `MAX_HOPS = 4`; la búsqueda es `view` (uso off-chain). |
| Sandwich en saltos intermedios | El `minOut` final protege toda la ruta; si algún salto rinde menos, revierte todo. |
| Fondos atascados en el router | Los saldos intermedios se consumen en el mismo tx; test verifica balance 0. |
| Transacción vieja ejecutada tarde | `deadline`. |

## Limitaciones

No divide órdenes entre rutas (split routing) y el DFS es exponencial: adecuado para grafos
chicos. En producción se usan algoritmos off-chain (Bellman-Ford sobre log-precios, optimización
convexa para splits).

## Tests (11)

Elección de ruta profunda sobre directa, límite de saltos, cotización = ejecución, `swapBest`,
slippage atómico, pool no registrado, token de salida incorrecto, deadline, token aislado,
control de acceso, y fuzz "la ruta elegida ≥ todas las alternativas".

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
