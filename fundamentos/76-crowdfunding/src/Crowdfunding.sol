// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Crowdfunding — financiamiento colectivo como máquina de estados
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #76
/// @notice Un creador fija una meta (en wei) y un plazo. Mientras la campaña
///         está activa cualquiera aporta ETH. Al vencer el plazo:
///         - si se alcanzó la meta, el creador retira todo lo recaudado;
///         - si NO se alcanzó, cada aportante recupera su aporte (reembolso).
/// @dev Patrón didáctico: **máquina de estados** + **pull over push**
///      (cada usuario retira lo suyo; nunca recorremos listas enviando ETH)
///      + **checks-effects-interactions** (CEI) para evitar reentrancia.
contract Crowdfunding {
    // ---------------------------------------------------------------------
    // Tipos
    // ---------------------------------------------------------------------

    /// @notice Estados posibles de la campaña.
    /// @dev El estado "efectivo" se calcula en `state()` combinando el valor
    ///      guardado con el tiempo actual: así no hace falta que nadie
    ///      "dispare" la transición al vencer el plazo.
    enum State {
        Active,     // 0: se aceptan aportes
        Successful, // 1: plazo vencido y meta alcanzada (pendiente de retiro)
        Failed,     // 2: plazo vencido sin alcanzar la meta (reembolsos)
        Paid        // 3: el creador ya retiró los fondos (estado final)
    }

    // ---------------------------------------------------------------------
    // Errores personalizados (más baratos que los strings de require)
    // ---------------------------------------------------------------------

    /// @notice La acción no está permitida en el estado actual.
    /// @param actual  Estado en el que está la campaña.
    /// @param esperado Estado que la acción requería.
    error InvalidState(State actual, State esperado);
    /// @notice Solo el creador puede ejecutar esta función.
    error NotCreator();
    /// @notice Se intentó aportar 0 wei.
    error ZeroContribution();
    /// @notice Parámetros del constructor inválidos.
    error InvalidParams();
    /// @notice El usuario no tiene nada para reembolsar.
    error NothingToRefund();
    /// @notice Falló el envío de ETH.
    error TransferFailed();

    // ---------------------------------------------------------------------
    // Eventos (para que un frontend siga la campaña)
    // ---------------------------------------------------------------------

    /// @notice Se registró un aporte.
    event Contributed(address indexed contributor, uint256 amount, uint256 totalRaised);
    /// @notice El creador retiró lo recaudado.
    event Withdrawn(address indexed creator, uint256 amount);
    /// @notice Un aportante recuperó su dinero.
    event Refunded(address indexed contributor, uint256 amount);

    // ---------------------------------------------------------------------
    // Almacenamiento
    // ---------------------------------------------------------------------

    /// @notice Dirección que lanzó la campaña y cobra si tiene éxito.
    /// @dev `immutable`: se fija en el constructor y queda embebido en el
    ///      bytecode, por lo que leerlo cuesta ~3 gas en vez de un SLOAD.
    address public immutable creator;
    /// @notice Meta de recaudación en wei.
    uint256 public immutable goal;
    /// @notice Timestamp (segundos Unix) en que termina la campaña.
    uint256 public immutable deadline;

    /// @notice Total recaudado hasta el momento.
    uint256 public totalRaised;
    /// @notice Aporte acumulado por dirección (necesario para reembolsar).
    mapping(address => uint256) public contributions;
    /// @dev Marca de que el creador ya cobró (lleva al estado `Paid`).
    bool private _paid;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param goal_      Meta en wei (debe ser > 0).
    /// @param duration_  Duración en segundos desde el despliegue (> 0).
    constructor(uint256 goal_, uint256 duration_) {
        if (goal_ == 0 || duration_ == 0) revert InvalidParams();
        creator = msg.sender;
        goal = goal_;
        // block.timestamp lo fija el validador; puede desviarse unos
        // segundos, por eso NO conviene usarlo para plazos muy cortos.
        deadline = block.timestamp + duration_;
    }

    // ---------------------------------------------------------------------
    // Lectura del estado
    // ---------------------------------------------------------------------

    /// @notice Devuelve el estado efectivo de la campaña "ahora".
    /// @dev Transición perezosa: el tiempo cambia el estado sin transacción.
    function state() public view returns (State) {
        if (_paid) return State.Paid;
        if (block.timestamp < deadline) return State.Active;
        return totalRaised >= goal ? State.Successful : State.Failed;
    }

    /// @dev Modificador que exige un estado concreto; si no, revierte con
    ///      un error que informa qué estado había y cuál se esperaba.
    modifier inState(State s) {
        State actual = state();
        if (actual != s) revert InvalidState(actual, s);
        _;
    }

    // ---------------------------------------------------------------------
    // Acciones
    // ---------------------------------------------------------------------

    /// @notice Aportar ETH a la campaña mientras esté activa.
    function contribute() public payable inState(State.Active) {
        if (msg.value == 0) revert ZeroContribution();
        // Solo efectos: no hay interacción externa, no hay riesgo de reentrada.
        contributions[msg.sender] += msg.value;
        totalRaised += msg.value;
        emit Contributed(msg.sender, msg.value, totalRaised);
    }

    /// @notice Enviar ETH "pelado" al contrato también cuenta como aporte.
    receive() external payable {
        contribute();
    }

    /// @notice El creador retira todo si la campaña tuvo éxito.
    function withdraw() external inState(State.Successful) {
        // CHECKS
        if (msg.sender != creator) revert NotCreator();
        // EFFECTS: marcamos pagado ANTES de enviar (anti-reentrancia).
        _paid = true;
        uint256 amount = address(this).balance;
        emit Withdrawn(creator, amount);
        // INTERACTIONS: `call` reenvía todo el gas; preferido a transfer().
        (bool ok,) = creator.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Cada aportante recupera su dinero si la campaña falló.
    function refund() external inState(State.Failed) {
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToRefund();
        // EFFECTS antes de INTERACTIONS: si el receptor reentra, verá 0.
        contributions[msg.sender] = 0;
        emit Refunded(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
