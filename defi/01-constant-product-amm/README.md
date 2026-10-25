# 01 · Constant Product AMM (clon de Uniswap V2)

**Nivel:** Intermedio

Réplica del AMM de producto constante `x · y = k`: fábrica de pares con CREATE2, par con tokens LP
(ERC-20), comisión de 0,3 % para los proveedores de liquidez, flash swaps, acumuladores de precio
para TWAP y un router con protección de slippage y deadline.

## Contratos

| Archivo | Rol |
|---|---|
| `src/CPAMMFactory.sol` | Crea un par por combinación de tokens (dirección determinística vía CREATE2). |
| `src/CPAMMPair.sol` | Custodia reservas, acuña/quema LP, ejecuta swaps y verifica el invariante `k`. |
| `src/CPAMMRouter.sol` | API para usuarios: `addLiquidity`, `removeLiquidity`, `swapExactTokensForTokens`, `swapTokensForExactTokens`, multi-hop. |
| `src/mocks/MockERC20.sol` | Token de prueba. |

## Diseño

- **Precio:** `p = y / x`. Un swap de `Δx` entrega `Δy = Δx·997·y / (x·1000 + Δx·997)`.
- **Liquidez inicial:** `sqrt(x·y) − 1000`; esos 1000 wei de LP se queman a `0xdead`.
- **Liquidez posterior:** `min(Δx/x, Δy/y) · totalSupply` → depositar fuera de ratio regala el excedente a los LP existentes.
- **Patrón "transferir y llamar":** el par mide lo recibido como `balance − reserva`, lo que habilita composición y flash swaps.

## Incentivos económicos

- **LP:** ganan el 0,3 % de cada swap (la comisión queda en las reservas y `k` crece). Asumen **pérdida impermanente** cuando el precio se mueve respecto del de depósito (ver proyecto 07).
- **Arbitrajistas:** alinean el precio del pool con el mercado externo; su ganancia es exactamente la pérdida (LVR) de los LP.
- **Traders:** pagan comisión + impacto de precio, que crece de forma convexa con el tamaño de la orden.

## Ataques posibles y defensas

| Ataque | Defensa |
|---|---|
| Sandwich / frontrunning | `amountOutMin` / `amountInMax` y `deadline` en el router. |
| Reentrancia en `swap` (callback de flash swap) | Cerrojo `lock` en todas las funciones de estado del par. |
| Robar con flash swap sin devolver | Chequeo de `k` ajustado por comisión al final de `swap`. |
| Inflación del primer depositante | Quema de `MINIMUM_LIQUIDITY`. |
| Overflow de reservas | `uint112` + chequeo explícito en `_update`. |
| Manipulación de oráculo en el mismo bloque | El acumulador usa reservas **previas** y solo avanza con el tiempo; para precios usá TWAP (proyecto 06), nunca el spot. |
| Tokens con fee-on-transfer / rebase | No soportados en el router (el par sí, vía `sync`/`skim`). Documentado como limitación. |

## Por qué es seguro

El invariante `(x'·1000 − 3·in_x)·(y'·1000 − 3·in_y) ≥ x·y·1000²` se verifica **después** de
cualquier transferencia y callback, por lo que ninguna secuencia de llamadas puede extraer valor
sin pagarlo. Los tests incluyen fuzzing del invariante `k`.

## Tests (14)

Quema de liquidez mínima, fórmula de swap, crecimiento de `k`, slippage, deadline, comisiones
para LP, multi-hop, swap exact-out, flash swap honesto y malicioso, robo directo, TWAP, fuzz.

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
