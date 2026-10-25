# 62 · Protocol Revenue Tracker (Intermedio)

Tesorería on-chain que **registra, agrega y reparte** los ingresos por comisiones de las distintas piezas de un protocolo (DEX, lending, etc.), con funciones de lectura pensadas para un dashboard.

## Estructura

| Ruta | Qué hay |
|---|---|
| `src/RevenueTracker.sol` | Registro por token, fuente y día; reparto por shares (pull); vistas para dashboard. |
| `src/MockFeeSources.sol` | `MockToken`, `MockDex` (0,3% por swap) y `MockLending` (paga en ETH): fuentes de ejemplo. |
| `test/RevenueTracker.t.sol` | 9 tests, incluido un fuzz de **solvencia**. |
| `script/Dashboard.s.sol` | "Lectura": simula 7 días e imprime un dashboard usando solo funciones `view`. |

```bash
forge test -vv
forge script script/Dashboard.s.sol --tc Dashboard -vv   # dashboard por consola (EVM local, no transmite)
```

Ejemplo de salida del dashboard:

```
===== DASHBOARD DE INGRESOS =====
USDC total (unidades): 8400
USDC ultimos 7 dias: 8400
 dia - 0 : 2100   ...   dia - 6 : 300
APR estimado (bps) sobre TVL 10M: 438
```

## Diseño

- **Fuentes autorizadas** (`setSource`): solo los contratos del protocolo pueden reportar. Así nadie infla las métricas con depósitos falsos.
- **Se mide lo recibido, no lo declarado**: `recordFee` compara el balance antes y después (soporta tokens con *fee-on-transfer*).
- **Tres agregaciones**: `totalRevenue[token]`, `revenueBySource[src][token]` y `dailyRevenue[token][día]`. Con la serie diaria un frontend calcula ingresos de 7 y 30 días y el APR sin indexer.
- **Reparto con acumulador por share** (estilo MasterChef): O(1) por cobro, sin bucles sobre beneficiarios. Al cambiar las shares, primero se **cristaliza** lo ganado (`credited`), así el cambio no es retroactivo.
- **Pull payments**: cada beneficiario hace `claim`. Si uno revierte al recibir ETH, no bloquea a los demás.

## Incentivos

Los beneficiarios típicos son la tesorería de la DAO y los stakers. Que el reparto sea transparente y on-chain hace creíble el "real yield" que el protocolo anuncia.

## Ataques posibles y defensas

| Ataque | Defensa |
|---|---|
| Inflar métricas reportando fees falsas | Solo fuentes activas. |
| Token con fee-on-transfer que descuadra la contabilidad | Medición por diferencia de balance. |
| Reentrada al reclamar ETH | `nonReentrant` + el estado se actualiza antes de transferir. |
| Cambio de shares para robar ingresos pasados | Cristalización previa. Test `test_ShareChangeNotRetroactive`. |
| Insolvencia por redondeo | El redondeo es hacia abajo. Un fuzz verifica que la suma de pendientes sea ≤ al balance (con polvo menor a 10 wei). |
| Fondos huérfanos sin beneficiarios | `recordFee` revierte si `totalShares == 0`. |

## Limitaciones

- `setShares` itera todos los tokens trackeados. Con muchos tokens conviene limitar la lista.
- Las vistas `revenueSeries` y `breakdown` tienen costo O(n), pensado para llamadas `eth_call` y no para uso on-chain.
