# 70 · Cross-Chain Rebase Token — Avanzado

Token **rebase** (el balance crece con el tiempo) que se puede **puentear entre cadenas conservando la tasa de interés** de cada usuario. La mensajería cross-chain se **simula** con un router mock, estilo CCIP.

| Ruta | Qué hay |
|---|---|
| `src/RebaseToken.sol` | ERC-20 con `balanceOf` dinámico, tasa por usuario y tasa global que solo puede bajar. |
| `src/Vault.sol` | ETH ⇄ RBT 1:1, más intereses (solo en la cadena origen). |
| `src/TokenPool.sol` | Puente burn & mint, con allowlist de pools remotos y anti-replay. |
| `src/MockRouter.sol` | "Red de mensajería": encola y entrega mensajes una vez. |
| `test/CrossChain.t.sol` | 12 tests, con dos cadenas simuladas en un solo EVM. |

## Mecánica

```
balanceOf(u) = principal(u) × (1 + rate(u) × (ahora − lastUpdated(u)))
```

- Al depositar, el usuario recibe la **tasa global vigente**. Gobernanza solo puede **bajarla**, así que los primeros depositantes quedan premiados para siempre (incentivo de adopción temprana).
- En cada mint, burn o transfer se **cristaliza** el interés: se acuña como principal y se reinicia el reloj.
- Transfer: si el receptor no tiene balance, **hereda la tasa del emisor**.

## Flujo cross-chain

```
Cadena A                                    Cadena B
alice ─bridge()─▶ TokenPoolA                TokenPoolB ─mint(to, monto, tasa)─▶ alice
                   │ burn (con interés)       ▲ verifica: msg.sender == router
                   └─ router.send(payload) ───┘          sourceChain/sourcePool en allowlist
                       (to, monto, tasa)                 messageId no procesado
```

## Incentivos

- **Usuarios**: interés pasivo y portabilidad entre cadenas sin perder la tasa.
- **Protocolo**: atrae TVL temprano. El interés se paga desde un fondo de recompensas en el vault, que sale del yield de la estrategia en un diseño real.

## Ataques y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Mensaje falso al pool destino | `msg.sender == router` y el pool origen debe estar en la allowlist | `test_RevertWhen_FakeRouterOrPool` |
| Replay del mismo mensaje | Router `delivered` más `processed[id]` en el pool | `test_RevertWhen_Replay` |
| Subir la tasa de una cuenta con tokens de alta tasa | Al acuñar sobre un balance existente se queda la **menor** | `test_BridgeCannotRaiseExistingRate` |
| Perder interés al puentear | Se cristaliza antes de quemar y viaja el monto con interés | `test_BridgePreservesRateAndInterest` |
| Inflar la tasa global | Solo puede bajar | `test_RateCanOnlyDecrease` |
| Cadena destino desconocida | `UnknownRemote` | `test_RevertWhen_UnknownDestination` |

### Riesgos conocidos (documentados, no resueltos)

1. **Transferencias "farming" de tasa**: un early adopter puede enviar 1 wei a direcciones nuevas para "regalarles" su tasa alta. Es inherente al diseño de herencia. Se mitiga si la tasa se fija en cada `mint` del vault (como acá), porque depósitos nuevos en esas direcciones bajan a la tasa vigente... salvo que se usen transfers.
2. **`totalSupply()` no incluye el interés pendiente.** Integraciones como AMMs o lending deben tratarlo con cuidado.
3. **El interés no está respaldado automáticamente**: si el fondo de recompensas del vault se agota, los últimos en retirar no cobran.
4. **Confianza en la red de mensajería**: un router comprometido puede acuñar sin límite en destino. En producción conviene CCIP con *rate limits* por pool (token bucket) y la Risk Management Network.

## De mock a producción (CCIP)

| Mock | CCIP real |
|---|---|
| `MockRouter.send` | `IRouterClient.ccipSend(destChainSelector, Client.EVM2AnyMessage)` y pago de fee en LINK o nativo |
| `receiveMessage` | `CCIPReceiver._ccipReceive(Client.Any2EVMMessage)`, o mejor, un `TokenPool` custom de CCIP con `lockOrBurn` / `releaseOrMint` |
| `deliver` manual | Entrega automática por la DON tras la finalidad de la cadena origen |
