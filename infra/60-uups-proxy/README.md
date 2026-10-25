# 60 · UUPS Proxy Upgradeable Contract (Avanzado)

Bóveda de ETH actualizable con el patrón **UUPS (EIP-1822)** detrás de un `ERC1967Proxy`, con migración V1 → V2 y almacenamiento **ERC-7201** (namespaced).

## Estructura

| Ruta | Qué hay |
|---|---|
| `src/VaultV1.sol` | Implementación 1: depósitos/retiros, owner, `_authorizeUpgrade`. |
| `src/VaultV2.sol` | Implementación 2: pausa, comisión de retiro acotada, `initializeV2` con `reinitializer(2)`. |
| `src/NotUUPS.sol` | Implementación "rota" para demostrar que el upgrade a algo no-UUPS se rechaza. |
| `test/UUPS.t.sol` | 11 tests (ciclo completo, ataques y fuzz de invariante). |

```bash
forge test -vv
```

## Cómo funciona UUPS

```
usuario ──call──▶ ERC1967Proxy ──delegatecall──▶ VaultV1 / VaultV2
                   (storage)                     (lógica + upgradeToAndCall)
```

- El proxy guarda la dirección de la implementación en el slot ERC-1967 `0x3608…bbc`.
- `upgradeToAndCall` vive en la implementación (hereda de `UUPSUpgradeable`) y llama a `_authorizeUpgrade`, que acá exige `onlyOwner`.
- Comparado con Transparent Proxy: el proxy es más barato (no chequea admin en cada llamada) y no hace falta `ProxyAdmin`.

## Almacenamiento ERC-7201

Cada versión guarda su estado en un `struct` ubicado en `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff`. V2 agrega un namespace **nuevo** (`VaultV2Ext`) en lugar de tocar el de V1, así es imposible que se pisen datos entre versiones.

## Ataques posibles y defensas

| Ataque | Defensa | Test |
|---|---|---|
| Inicializar la implementación y tomar control | `_disableInitializers()` en el constructor | `test_RevertWhen_InitializeImplementation` |
| Reinicializar el proxy para cambiar el owner | `initializer` / `reinitializer(2)` | `test_RevertWhen_ReInitialize`, `test_RevertWhen_ReinitializeV2` |
| Upgrade por un tercero | `_authorizeUpgrade` con `onlyOwner` | `test_RevertWhen_NonOwnerUpgrades` |
| Upgrade a una implementación sin UUPS (proxy congelado) | OZ verifica `proxiableUUID()` | `test_RevertWhen_UpgradeToNonUUPS` |
| Llamar `upgradeToAndCall` sobre la implementación | `onlyProxy` de OZ | `test_RevertWhen_UpgradeOnImplementationDirectly` |
| Colisión de storage entre versiones | ERC-7201 | `test_UpgradePreservesState` |
| Owner que pone una comisión abusiva | `MAX_FEE_BPS = 5%` hardcodeado | `test_RevertWhen_FeeTooHigh` |

## Incentivos y confianza

El owner puede cambiar la lógica, así que **los usuarios confían en el owner**. En producción conviene que el owner sea una multisig (ver proyecto 58) con timelock (proyecto 43), para que los usuarios tengan tiempo de salir antes de un upgrade que no les guste.

## Limitaciones

- No hay timelock integrado. En V2, el owner puede pausar los retiros indefinidamente.
