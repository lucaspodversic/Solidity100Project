# 100. Decentralized Raffle with Chainlink VRF

**Nivel:** Intermedio · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Rifa con aleatoriedad verificable: solicitud al VRF Coordinator, estado CALCULATING mientras se espera y callback que elige y paga al ganador. Testeada con un mock del Coordinator.

## Archivos
- `src/VRFInterfaces.sol` — interfaz mínima del Coordinator y base `VRFConsumerBaseMinimal`.
- `src/VRFCoordinatorMock.sol` — mock para tests.
- `src/Raffle.sol` — la rifa.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. `new Raffle(coordinator, fee, intervalo, keyHash, subId, callbackGas)`.
2. Jugadores: `enter{value: fee}()`.
3. Cuando `checkUpkeep()` es true: `requestWinner()` (o Chainlink Automation).
4. El Coordinator llama `rawFulfillRandomWords` y se paga el pozo.

Para testnet/mainnet reemplazar las interfaces mínimas por `VRFConsumerBaseV2Plus` del paquete oficial de Chainlink y crear una suscripción VRF.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Solo el Coordinator puede entregar el número (`OnlyCoordinatorCanFulfill`).
- No se aceptan jugadores en CALCULATING.
- `fulfillRandomWords` no debería revertir (Chainlink no reintenta); en producción conviene registrar el premio y que el ganador lo retire (pull).
- El mock NO tiene prueba criptográfica: solo para tests.

## Consideraciones de gas
- `callbackGasLimit` debe cubrir el callback; `NUM_WORDS = 1` minimiza costo.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
