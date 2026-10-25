# 76. Crowdfunding

**Nivel:** Principiante · **Lote D — Fundamentos y Patrones** · Solidity ^0.8.20 (compilado con 0.8.24, EVM cancun) · Foundry

## Patrón que demuestra
Máquina de estados (Active → Successful/Failed → Paid) con plazos basados en `block.timestamp` y reembolsos *pull*.

## Archivos
- `src/Crowdfunding.sol` — campaña con meta, plazo, aportes, retiro del creador y reembolsos.
- `test/` — tests de Foundry (unitarios, reverts y fuzzing).

## Uso
1. El creador despliega `new Crowdfunding(meta, duracion)`.
2. Los aportantes llaman `contribute()` o envían ETH directo (`receive`).
3. Vencido el plazo: si `totalRaised >= goal` el creador llama `withdraw()`; si no, cada aportante llama `refund()`.

## Compilar y testear
```bash
# Requiere Foundry (https://getfoundry.sh). Las dependencias (forge-std y
# OpenZeppelin v5.1) se comparten en ../lib.
forge build
forge test -vv
forge test --gas-report
```

## Consideraciones de seguridad
- Transición de estado *perezosa*: `state()` se calcula con el tiempo, no requiere una tx que la dispare.
- Patrón checks-effects-interactions: se marca `_paid`/se pone a cero el aporte ANTES de enviar ETH.
- Pull over push: nunca se recorre una lista enviando ETH (evita DoS por gas o por receptores que revierten).
- `block.timestamp` puede desviarse unos segundos: no usar plazos muy cortos.

## Consideraciones de gas
- `immutable` para creador/meta/plazo: lectura ~3 gas en vez de SLOAD (2100).
- Errores personalizados en vez de strings.

> Código didáctico, comentado en español. No auditado: no usar con fondos reales sin auditoría.
