// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title TaskBoard — emisión de eventos para frontends e indexadores
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #91
/// @notice Un tablero de tareas mínimo cuyo propósito real es mostrar cómo
///         diseñar eventos: qué indexar, qué no, y cómo escucharlos (ver el
///         README con el ejemplo en ethers.js v6).
/// @dev Teoría de logs en la EVM:
///   - Un evento genera un LOG con hasta 4 "topics" de 32 bytes + "data".
///   - topic0 = keccak256("NombreEvento(tipos)") (salvo eventos `anonymous`).
///   - Cada parámetro `indexed` ocupa un topic (máx. 3) y permite FILTRAR
///     por ese valor en `eth_getLogs`. Los no indexados van en `data`
///     (más baratos y decodificables, pero no filtrables).
///   - Indexar un `string`/`bytes` guarda su HASH, no el texto: por eso
///     `title` va sin indexar.
///   - Costo: 375 gas base + 375 por topic + 8 por byte de data. Mucho más
///     barato que storage, pero los contratos NO pueden leer logs.
contract TaskBoard {
    /// @notice Estados de una tarea.
    enum Status { Open, Done, Cancelled }

    struct Task {
        address owner;
        Status status;
        string title;
    }

    /// @notice Nueva tarea. Indexamos id y dueño para filtrar "mis tareas".
    event TaskCreated(uint256 indexed id, address indexed owner, string title);
    /// @notice Cambio de estado. Indexamos también el nuevo estado.
    event TaskStatusChanged(uint256 indexed id, address indexed owner, Status indexed newStatus);
    /// @notice Evento anónimo: no tiene topic0 (ahorra 375 gas) pero no se
    ///         puede filtrar por firma. Uso raro; aquí es solo didáctico.
    event Ping(address indexed from, uint256 at) anonymous;

    error NotTaskOwner();
    error InvalidTask();
    error NotOpen();

    /// @notice Tareas por id (ids desde 1).
    mapping(uint256 => Task) public tasks;
    uint256 public nextId = 1;

    /// @notice Crear tarea.
    function create(string calldata title) external returns (uint256 id) {
        id = nextId++;
        tasks[id] = Task(msg.sender, Status.Open, title);
        emit TaskCreated(id, msg.sender, title);
    }

    /// @notice Marcar como hecha.
    function complete(uint256 id) external {
        _setStatus(id, Status.Done);
    }

    /// @notice Cancelar.
    function cancel(uint256 id) external {
        _setStatus(id, Status.Cancelled);
    }

    /// @notice Emite el evento anónimo.
    function ping() external {
        emit Ping(msg.sender, block.timestamp);
    }

    function _setStatus(uint256 id, Status s) internal {
        Task storage t = tasks[id];
        if (t.owner == address(0)) revert InvalidTask();
        if (t.owner != msg.sender) revert NotTaskOwner();
        if (t.status != Status.Open) revert NotOpen();
        t.status = s;
        emit TaskStatusChanged(id, msg.sender, s);
    }
}
