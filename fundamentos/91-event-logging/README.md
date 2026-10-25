# 91. Event Logging & Frontend Listeners

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Diseño de eventos (indexed vs data, eventos anónimos) y cómo escucharlos desde un frontend.

## Archivos
- `src/EventEmitter.sol` — `TaskBoard` con `TaskCreated`, `TaskStatusChanged`, `Ping` (anónimo).
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
`forge test -vvvv` muestra los logs. Ejemplo de escucha con **ethers.js v6** (sin front obligatorio):

```js
import { ethers } from "ethers";

const provider = new ethers.WebSocketProvider("wss://TU_RPC");
const abi = [
  "event TaskCreated(uint256 indexed id, address indexed owner, string title)",
  "event TaskStatusChanged(uint256 indexed id, address indexed owner, uint8 indexed newStatus)",
];
const board = new ethers.Contract("0xDIRECCION_TASKBOARD", abi, provider);

// 1) Escuchar en tiempo real todos los TaskCreated
board.on("TaskCreated", (id, owner, title, event) => {
  console.log(`Tarea #${id} de ${owner}: ${title} (bloque ${event.log.blockNumber})`);
});

// 2) Filtrar solo MIS tareas (gracias a `owner` indexado)
const mias = board.filters.TaskCreated(null, "0xMI_DIRECCION");
board.on(mias, (id, owner, title) => console.log("Nueva tarea mía:", title));

// 3) Consultar el historial (eth_getLogs) de los últimos 10.000 bloques
const desde = (await provider.getBlockNumber()) - 10_000;
const logs = await board.queryFilter(board.filters.TaskStatusChanged(), desde);
for (const l of logs) console.log(l.args.id, l.args.newStatus);
```

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Los contratos no pueden leer logs: no guardes ahí datos que la lógica necesite.
- Indexar `string` guarda su hash, no el texto.
- Los frontends deben tolerar reorganizaciones (esperar confirmaciones).

## Consideraciones de gas
- LOG: 375 base + 375 por topic + 8 gas/byte de data; mucho más barato que storage.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
