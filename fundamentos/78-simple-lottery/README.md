# 78. Simple Lottery

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Lotería con selección **pseudoaleatoria** usando `block.prevrandao`. Documenta (y demuestra en un test) por qué esa aleatoriedad es insegura.

## Archivos
- `src/SimpleLottery.sol` — boletos a precio fijo, rondas con plazo, sorteo y pago del pozo.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. `new SimpleLottery(precio, duracionRonda)`.
2. Jugadores: `enter{value: precio}()`.
3. Pasado el plazo, el organizador llama `pickWinner()`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- ⚠️ **La aleatoriedad es manipulable**: el validador conoce `prevrandao` y puede retener un bloque que no le conviene; otros contratos pueden calcular el mismo valor en la misma tx. El test `test_AleatoriedadManipulable` lo demuestra fijando `prevrandao` hasta elegir al ganador.
- Para dinero real: Chainlink VRF (ver proyecto 100) o commit-reveal.
- `delete players` cuesta gas proporcional al tamaño; con miles de jugadores podría exceder el límite de bloque.

## Consideraciones de gas
- Un boleto = un `push` (~22k gas el primer slot).

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
