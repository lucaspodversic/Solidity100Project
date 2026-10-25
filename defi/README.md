# Lote DeFi: 29 proyectos Foundry (01–29)

Cada carpeta es un proyecto Foundry **independiente**, con su propio `foundry.toml`, `src/`, `test/` y, cuando corresponde, `script/`. Cada una trae un README en español que cubre diseño, incentivos, ataques y seguridad.
Los contratos auxiliares (mocks, oráculo, perpetuo) están **copiados** dentro de cada proyecto: no hay imports entre carpetas.

Toolchain: Solidity 0.8.24 (`pragma ^0.8.20`), EVM cancun, optimizer 200 + `via_ir`, OpenZeppelin v5.1.0.
Las dependencias están compartidas en `lib/`, que es `forge-std` + `openzeppelin-contracts`.

**Total: 352 tests (unitarios + fuzz), todos pasando.**

| # | Proyecto | Tests |
|---|---|---|
| 01 | [Constant Product AMM (clon de Uniswap V2)](01-constant-product-amm/README.md) | 14 |
| 02 | [Concentrated Liquidity DEX (estilo Uniswap V3)](02-concentrated-liquidity-dex/README.md) | 17 |
| 03 | [Multi-hop Router](03-multi-hop-router/README.md) | 11 |
| 04 | [Limit Order Book DEX](04-limit-order-book-dex/README.md) | 13 |
| 05 | [Stableswap (estilo Curve)](05-stableswap/README.md) | 14 |
| 06 | [TWAP Oracle sobre el AMM propio](06-twap-oracle/README.md) | 9 |
| 07 | [Impermanent Loss Calculator](07-impermanent-loss-calculator/README.md) | 12 |
| 08 | [Gas-Optimized Multicall](08-gas-optimized-multicall/README.md) | 14 |
| 09 | [Simple Lending (depósitos, préstamos, intereses y liquidaciones)](09-simple-lending/README.md) | 15 |
| 10 | [Isolated Lending Markets (estilo Silo / Morpho Blue)](10-isolated-lending-markets/README.md) | 12 |
| 11 | [Interest Rate Model Simulator](11-interest-rate-model-simulator/README.md) | 12 |
| 12 | [Liquidation Bot (contrato + script)](12-liquidation-bot/README.md) | 11 |
| 13 | [Credit Delegation (estilo Aave)](13-credit-delegation/README.md) | 13 |
| 14 | [Health Factor Dashboard (vista on-chain + script)](14-health-factor-dashboard/README.md) | 12 |
| 15 | [Flash Loan Executor (recetas modulares con adapters)](15-flash-loan-executor/README.md) | 11 |
| 16 | [Position Manager (multi-protocolo con rebalanceo)](16-position-manager/README.md) | 11 |
| 17 | [DeFi Position Simulator (contrato `pure` + script)](17-defi-position-simulator/README.md) | 11 |
| 18 | [ERC-4626 Vault (implementación desde cero, con fees)](18-erc4626-vault/README.md) | 12 |
| 19 | [Auto-compounding Vault](19-auto-compounding-vault/README.md) | 10 |
| 20 | [Multi-strategy Vault](20-multi-strategy-vault/README.md) | 15 |
| 21 | [Yield Aggregator](21-yield-aggregator/README.md) | 11 |
| 22 | [Recursive Lending Strategy (looping LST/WETH)](22-recursive-lending-strategy/README.md) | 14 |
| 23 | [Vault Share Accounting: ataques de donación y redondeo](23-vault-share-accounting/README.md) | 11 |
| 24 | [Delta-Neutral Vault: cash & carry con funding](24-delta-neutral-vault/README.md) | 9 |
| 25 | [Perpetual Futures: funding por skew, margen y liquidaciones](25-perpetual-futures/README.md) | 15 |
| 26 | [Options Protocol: calls y puts europeas con colateral completo](26-options-protocol/README.md) | 10 |
| 27 | [Synthetic Asset Minter: CDPs con stability fee](27-synthetic-asset-minter/README.md) | 11 |
| 28 | [Prediction Market: binario con FPMM y resolución optimista](28-prediction-market/README.md) | 12 |
| 29 | [Funding Rate Arbitrage Bot (contrato + script)](29-funding-rate-arbitrage-bot/README.md) | 10 |

## Correr todo

```bash
for d in [0-2][0-9]-*/; do (cd "$d" && echo "== $d" && forge test); done
```

## Crear un proyecto nuevo con la misma configuración

Copiá el `foundry.toml` de cualquier carpeta. Todos son idénticos y apuntan a `libs = ["../lib"]` con los remappings `forge-std/` y `@openzeppelin/contracts/`.

> Código educativo, no auditado. No lo uses en mainnet con fondos reales sin una auditoría profesional.
