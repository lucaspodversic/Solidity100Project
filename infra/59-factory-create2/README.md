# 59 · Factory Pattern Deployment (Intermedio)

Fábrica que despliega instancias de un contrato (`PiggyBank`, una alcancía con desbloqueo temporal) usando **tres estrategias** y las compara.

## Estructura

| Ruta | Qué hay |
|---|---|
| `src/PiggyBank.sol` | Producto desplegado. Constructor clásico + `initialize` para clones. |
| `src/PiggyBankFactory.sol` | Fábrica: `createBank` (CREATE), `createBank2` (CREATE2), `createBankClone` (EIP-1167 + CREATE2), predicciones y registro. |
| `test/PiggyBankFactory.t.sol` | 10 tests (incluye fuzz de predicción y comparación de gas). |

```bash
forge test -vv   # muestra el gas de cada modo
```

## Las tres estrategias

| Modo | Opcode | Dirección | Gas aprox. (test) | Cuándo usarlo |
|---|---|---|---|---|
| `createBank` | CREATE | `keccak(rlp(factory, nonce))` → no predecible por el usuario | ~401k | Simple, sin necesidad de dirección conocida. |
| `createBank2` | CREATE2 | `keccak(0xff ‖ factory ‖ salt ‖ keccak(initcode))` → predecible | ~361k | Direcciones contrafácticas (recibir fondos antes de existir), mismas direcciones multi-cadena. |
| `createBankClone` | CREATE2 + EIP-1167 | depende solo de (factory, salt, impl) | ~191k | Muchas instancias baratas de la misma lógica. |

## Decisiones de seguridad

- **Sal ligada al remitente** (`keccak256(msg.sender, salt)`): sin esto, un atacante que ve en la mempool la sal de Alice podría desplegar primero en "su" dirección (en el caso de clones, inicializándolo con él como dueño). Test `test_SaltBoundToSender`.
- **Clon + inicialización atómica**: el clon se crea e inicializa en la misma transacción, así nadie puede ganarle el `initialize`.
- **Implementación bloqueada**: la instancia usada como implementación se construye con owner cero y queda marcada como inicializada. Test `test_ImplementationLocked`.
- **Registro `isFromFactory`**: otros contratos pueden verificar de forma barata que una dirección fue creada por la fábrica (por ejemplo, para darle permisos).

## Ataques posibles

| Ataque | Mitigación |
|---|---|
| Front-running de la sal CREATE2 | Sal ligada a `msg.sender`. |
| Toma de control de la implementación | Bloqueada en el constructor. |
| Reinicialización de un clon | Bandera `_initialized`. |
| Redeploy en la misma dirección | CREATE2 falla si la dirección ya tiene código (test `test_RevertWhen_Create2SameSaltTwice`). |

## Incentivos / economía

Los clones bajan ~50% el costo de despliegue, a cambio de un `DELEGATECALL` extra (~2.6k gas) en cada llamada. Conviene cuando hay muchas instancias que se usan poco.

## Limitaciones

- `PiggyBank` es deliberadamente mínimo. Cuando una colisión de CREATE2 revierte, se consume todo el gas enviado (comportamiento de la EVM).
