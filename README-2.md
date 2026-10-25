# 100 Proyectos Solidity

Colección de 100 proyectos Solidity independientes, cada uno en su propia carpeta,
organizados por categoría y nivel de dificultad. Cada proyecto es un proyecto
**Foundry** autónomo (`foundry.toml`, `src/`, `test/`, `README.md` en español)
con comentarios detallados en español, tests que pasan con `forge test`, y un
README que explica el diseño, los incentivos económicos, los ataques posibles y
las consideraciones de seguridad.

## Categorías

| Carpeta | Proyectos | Tema |
|---|---|---|
| `defi/` | 01–29 | DeFi: AMM/DEX, lending, vaults, derivados y sintéticos |
| `nft/` | 30–39 | NFT y tokenización |
| `dao/` | 40–47 | DAO y gobernanza |
| `seguridad/` | 48–57 | Seguridad y auditoría (vulnerable + PoC + defensa) |
| `infra/` | 58–65 | Infraestructura y herramientas |
| `avanzado/` | 66–75 | Avanzado / especializado |
| `fundamentos/` | 76–100 | Fundamentos y patrones |

**Total: 100 proyectos · 362 archivos .sol · 111 proyectos Foundry · 847 tests (todos pasan): DeFi 352, NFT/DAO/Seguridad 84, Infra/Avanzado 249, Fundamentos 162.**

## Cómo compilar y testear

Cada categoría comparte una carpeta `lib/` (forge-std + OpenZeppelin v5.1.0) y los
proyectos la referencian con `libs = ["../lib"]`. Para probar un proyecto:

```bash
cd defi/01-constant-product-amm
forge build
forge test
forge test --gas-report   # opcional
```

> Si copiás una carpeta de proyecto fuera de su categoría, llevate también el
> `lib/` de esa categoría (o corré `forge install` y ajustá los remappings).

## Aviso

Todo el código es **educativo y no está auditado**. No usar en producción sin una
auditoría profesional. Cada README lista las limitaciones específicas del proyecto
(oráculos mock, componentes off-chain simulados, árbitros centralizados, etc.).

## Licencia

MIT.
