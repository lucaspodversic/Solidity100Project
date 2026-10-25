// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Comparativa de costos de almacenamiento: struct vs mappings
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #86
/// @notice Guardamos el mismo dato de usuario (saldo, último acceso, activo,
///         nivel) de cuatro formas y comparamos el gas en los tests
///         (`forge test --gas-report` y mediciones con `gasleft()`).
/// @dev Reglas del almacenamiento EVM que explican los resultados:
///   - Cada slot mide 32 bytes. Escribir un slot de 0 a no-cero cuesta
///     ~22.100 gas (20.000 + 2.100 de acceso "frío"); modificar un slot ya
///     no-cero ~5.000; leer un slot frío 2.100 y caliente 100.
///   - Variables contiguas que suman ≤ 32 bytes se **empaquetan** en un mismo
///     slot. Un struct bien ordenado con tipos chicos ocupa 1 slot.
///   - Varios mappings separados = varios slots (uno por mapping) por usuario.

/// @notice Variante A: struct **empaquetado** en 1 slot (128+64+8+8 = 208 bits).
contract PackedStruct {
    struct User {
        uint128 balance;    // 16 bytes
        uint64 lastSeen;    // 8 bytes
        bool active;        // 1 byte
        uint8 level;        // 1 byte  -> total 26 bytes: cabe en 1 slot
    }
    mapping(address => User) public users;

    function set(address u, uint128 bal, uint64 t, bool a, uint8 l) external {
        // Una sola escritura de slot: construimos el struct en memoria y lo copiamos.
        users[u] = User(bal, t, a, l);
    }

    function updateBalance(address u, uint128 bal) external {
        // Modificar un campo implica leer-modificar-escribir el slot completo.
        users[u].balance = bal;
    }

    function get(address u) external view returns (uint128, uint64, bool, uint8) {
        User memory x = users[u]; // 1 SLOAD
        return (x.balance, x.lastSeen, x.active, x.level);
    }
}

/// @notice Variante B: struct **no empaquetado** (uint256 + bool + uint256 + bool => 4 slots).
contract UnpackedStruct {
    struct User {
        uint256 balance;   // slot 0
        bool active;       // slot 1 (el siguiente uint256 no entra con él)
        uint256 lastSeen;  // slot 2
        bool level;        // slot 3 (aquí simplificado a bool)
    }
    mapping(address => User) public users;

    function set(address u, uint256 bal, uint256 t, bool a, bool l) external {
        users[u] = User(bal, a, t, l);
    }

    function updateBalance(address u, uint256 bal) external {
        users[u].balance = bal;
    }

    function get(address u) external view returns (uint256, uint256, bool, bool) {
        User memory x = users[u]; // 4 SLOAD
        return (x.balance, x.lastSeen, x.active, x.level);
    }
}

/// @notice Variante C: un mapping por campo (4 slots por usuario, sin empaquetar).
contract SeparateMappings {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lastSeen;
    mapping(address => bool) public active;
    mapping(address => uint8) public level;

    function set(address u, uint256 bal, uint256 t, bool a, uint8 l) external {
        balanceOf[u] = bal;
        lastSeen[u] = t;
        active[u] = a;
        level[u] = l;
    }

    function updateBalance(address u, uint256 bal) external {
        // Ventaja: tocar un solo campo es un solo slot independiente.
        balanceOf[u] = bal;
    }

    function get(address u) external view returns (uint256, uint256, bool, uint8) {
        return (balanceOf[u], lastSeen[u], active[u], level[u]);
    }
}

/// @notice Variante D: array de structs (iterable pero con costos de push/longitud).
contract StructArray {
    struct User {
        address account;   // 20 bytes
        uint64 lastSeen;   // 8 bytes  -> slot 0 (28 bytes)
        uint128 balance;   // slot 1
    }
    User[] public users;

    function push(address u, uint128 bal, uint64 t) external {
        // push escribe la longitud (1 slot) + 2 slots de datos.
        users.push(User(u, t, bal));
    }

    /// @notice Buscar en un array es O(n): ¡caro y riesgoso con muchas entradas!
    function find(address u) external view returns (uint128) {
        for (uint256 i; i < users.length; ++i) {
            if (users[i].account == u) return users[i].balance;
        }
        return 0;
    }
}
