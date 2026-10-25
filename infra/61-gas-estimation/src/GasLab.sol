// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GasLab — Experimentos de costo de gas en estructuras de datos
/// @notice Cada contrato implementa la MISMA operación lógica ("guardar un usuario
///         con id, saldo y flag activo") usando una estructura distinta, para
///         comparar el gas con `forge test --gas-report` y con los logs de los tests.
/// @dev Costos de referencia (post-Berlin / EIP-2929):
///      - SSTORE de 0 → no-cero: 22.100 gas (20.000 + 2.100 de acceso frío).
///      - SSTORE no-cero → no-cero: 5.000 (2.900 + 2.100 frío).
///      - SLOAD frío 2.100 / caliente 100.
///      Empaquetar varios campos en un mismo slot de 32 bytes reduce SSTOREs.

/// @notice Estructura SIN empaquetar: 3 slots (uint256, uint256, bool).
struct UserLoose {
    uint256 id;      // slot 0
    uint256 balance; // slot 1
    bool active;     // slot 2 (un slot entero para 1 byte)
}

/// @notice Estructura EMPAQUETADA: 1 slot (uint64 + uint128 + bool = 25 bytes ≤ 32).
struct UserPacked {
    uint64 id;
    uint128 balance;
    bool active;
}

/// @title Variante 1: array dinámico de structs sueltos
/// @dev Búsqueda por id es O(n): el costo crece con la cantidad de elementos.
contract ArrayStore {
    UserLoose[] public users;

    /// @notice Agrega un usuario al final (3 SSTORE de slots nuevos + longitud).
    function add(uint256 id, uint256 balance) external {
        users.push(UserLoose(id, balance, true));
    }

    /// @notice Busca linealmente: costo O(n) en SLOADs.
    function find(uint256 id) external view returns (uint256 balance) {
        uint256 len = users.length; // cachear la longitud evita un SLOAD por vuelta
        for (uint256 i; i < len; ++i) {
            if (users[i].id == id) return users[i].balance;
        }
        revert("no encontrado");
    }

    /// @notice Actualiza el saldo buscando linealmente.
    function update(uint256 id, uint256 balance) external {
        uint256 len = users.length;
        for (uint256 i; i < len; ++i) {
            if (users[i].id == id) {
                users[i].balance = balance;
                return;
            }
        }
        revert("no encontrado");
    }
}

/// @title Variante 2: mapping de structs sueltos
/// @dev Acceso O(1): slot = keccak256(id, slotDelMapping). No se puede iterar.
contract MappingStore {
    mapping(uint256 => UserLoose) public users;

    function add(uint256 id, uint256 balance) external {
        users[id] = UserLoose(id, balance, true);
    }

    function find(uint256 id) external view returns (uint256) {
        return users[id].balance;
    }

    function update(uint256 id, uint256 balance) external {
        users[id].balance = balance;
    }
}

/// @title Variante 3: mapping de structs empaquetados
/// @dev Igual que la 2 pero el struct ocupa 1 slot: `add` hace 1 SSTORE en vez de 3.
contract PackedMappingStore {
    mapping(uint256 => UserPacked) public users;

    function add(uint64 id, uint128 balance) external {
        users[id] = UserPacked(id, balance, true);
    }

    function find(uint64 id) external view returns (uint128) {
        return users[id].balance;
    }

    /// @dev Escribir un campo de un slot empaquetado implica leer-modificar-escribir
    ///      el slot completo (el compilador lo hace con máscaras).
    function update(uint64 id, uint128 balance) external {
        users[id].balance = balance;
    }
}

/// @title Variante 4: mappings paralelos (una "columna" por campo)
/// @dev Útil cuando se lee/escribe un solo campo muy seguido.
contract ParallelMappingsStore {
    mapping(uint256 => uint256) public balanceOf;
    mapping(uint256 => bool) public isActive;

    function add(uint256 id, uint256 balance) external {
        balanceOf[id] = balance;
        isActive[id] = true;
    }

    function find(uint256 id) external view returns (uint256) {
        return balanceOf[id];
    }

    function update(uint256 id, uint256 balance) external {
        balanceOf[id] = balance;
    }
}

/// @title Micro-experimentos varios
/// @notice Patrones comunes de optimización comparados lado a lado.
contract MicroOpts {
    uint256[] public data;
    uint256 public total;

    /// @notice Carga datos de prueba.
    function seed(uint256 n) external {
        for (uint256 i; i < n; ++i) data.push(i);
    }

    /// @notice Suma leyendo `data.length` y `total` de storage en cada vuelta (ingenuo).
    function sumNaive() external {
        for (uint256 i = 0; i < data.length; i++) {
            total += data[i]; // SLOAD + SSTORE por iteración
        }
    }

    /// @notice Suma con longitud cacheada, acumulador en memoria y `unchecked` en el índice.
    function sumOptimized() external {
        uint256 len = data.length;
        uint256 acc;
        for (uint256 i; i < len;) {
            acc += data[i];
            unchecked { ++i; } // i < len garantiza que no hay overflow
        }
        total += acc; // una sola escritura
    }

    /// @notice Recibe un array como `memory` (se copia el calldata a memoria).
    function sumMemory(uint256[] memory xs) external pure returns (uint256 s) {
        for (uint256 i; i < xs.length; ++i) s += xs[i];
    }

    /// @notice Recibe el mismo array como `calldata` (sin copia).
    function sumCalldata(uint256[] calldata xs) external pure returns (uint256 s) {
        for (uint256 i; i < xs.length; ++i) s += xs[i];
    }

    /// @notice Revert con string (más bytecode y más gas al revertir).
    function revertString() external pure {
        revert("Este es un mensaje de error largo para comparar costos");
    }

    /// @notice Error personalizado (4 bytes de selector).
    error CustomError();

    function revertCustom() external pure {
        revert CustomError();
    }
}
