# 13 · Credit Delegation (estilo Aave)

**Nivel:** Avanzado

Un usuario con colateral (el **delegador**) autoriza a otro (el **delegado**) a pedir
prestado contra ese colateral. El delegado recibe los fondos sin poner garantía, y la deuda
queda a nombre del delegador. Además incluye un contrato de **acuerdos on-chain** con prima,
vencimiento y default.

## Contratos

| Archivo | Rol |
|---|---|
| `src/DelegatedLendingPool.sol` | Hereda el LendingPool del proyecto 09 y agrega `approveDelegation`, `delegationWithSig` (EIP-712) y `borrowOnBehalf`. |
| `src/CreditAgreement.sol` | Acuerdos con límite, prima anual y vencimiento: `create`, `draw`, `repay` (la prima va al delegador y el principal al pool), `markDefault` y `cancel`. |
| `src/protocol/*` | Copia del LendingPool del proyecto 09. |

## Diseño

- `borrowAllowance[delegador][activo][delegado]`:
  - `approveDelegation` **fija** el valor (no lo suma); para revocar, se pasa 0;
  - con `type(uint256).max` la allowance es infinita y no se descuenta.
- `borrowOnBehalf(asset, amount, onBehalfOf)`:
  - descuenta la allowance;
  - suma la deuda escalada al **delegador**;
  - verifica el LTV de la cuenta del **delegador**;
  - transfiere los fondos al **delegado**.
- `delegationWithSig`: el delegador firma off-chain y cualquiera lo relayea (gasless).
  Lleva nonce por delegador, deadline y domain separator con chainId y la dirección del pool.
- `CreditAgreement` es el delegado on-chain:
  - el delegador le delega a **ese contrato**, con términos auditables;
  - el contrato solo deja retirar al delegado del acuerdo, hasta el límite y antes del
    vencimiento;
  - en cada repago se cubre primero la prima y después el principal;
  - si al vencimiento queda saldo, cualquiera puede marcar default, lo que queda como evento
    público de reputación.

## Incentivos económicos

- **Delegador:** tiene colateral ocioso (por ejemplo ETH que no quiere vender) y cobra una
  **prima** por prestar su capacidad de endeudamiento. Para ganar, la prima tiene que superar
  la tasa variable del pool, que corre a su cargo.
- **Delegado:** consigue liquidez sin colateral, por ejemplo un market maker o una DAO.
  Paga más que la tasa del pool, pero no inmoviliza capital.
- **Riesgo:** si el delegado no paga, el delegador conserva la deuda y puede ser liquidado
  si cae el precio del colateral. Por eso la delegación se usa entre partes con confianza o
  con acuerdo legal (Aave + OpenLaw), o con contratos como `CreditAgreement` que limitan los
  montos y los plazos.

## Ataques y defensas

| Ataque | Defensa |
|---|---|
| Endeudar a alguien sin permiso | Hace falta allowance explícita (`InsufficientAllowance`). |
| Pedir prestado por encima del LTV del delegador | Chequeo de `accountData(onBehalfOf)` (test `DelegatorHealthLimitsDelegation`). |
| Replay de la firma | Nonce incremental (test `DelegationWithSig`) y domain separator con chainId. |
| Firma vencida o manipulada | `ExpiredSignature` e `InvalidSignature` (tests). |
| Race condition al cambiar la allowance (como `approve` de ERC-20) | Para bajarla conviene pasar primero por 0. Es un riesgo conocido y está documentado. |
| Retirar después del vencimiento o por encima del límite | `Matured` y `OverLimit`. |
| Cancelar con deuda pendiente | `Outstanding`. |
| Reentrancia en draw y repay | `nonReentrant`. |

## Limitaciones

- `CreditAgreement` no imputa al delegado el interés variable del pool: ese costo lo cubre
  la prima.
- `cancel` no revoca la allowance en el pool: el delegador tiene que llamar
  `approveDelegation(asset, agreement, 0)`.
- El default no tiene enforcement on-chain: es crédito no colateralizado por diseño.

## Tests

13 tests (1 de fuzz):
- deuda imputada al delegador;
- sin allowance y allowance excedida;
- límite por HF;
- revocación;
- firma EIP-712, replay, vencimiento y manipulación;
- acuerdo con prima;
- límites y autorización;
- default con recupero;
- cancelación;
- fuzz de deuda ≤ allowance.


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
