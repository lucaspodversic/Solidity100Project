// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Autodestrucción tras EIP-6780 (Cancun, marzo 2024)
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #89
/// @notice `selfdestruct(beneficiario)` ya NO borra el contrato, salvo que se
///         ejecute en la MISMA transacción en que el contrato fue creado.
///         En cualquier otro caso solo **envía todo el ETH** al beneficiario;
///         el código y el almacenamiento quedan intactos.
/// @dev Consecuencias prácticas:
///   - No sirve como "botón de apagado": el contrato sigue funcionando.
///   - Patrones "metamórficos" (CREATE2 + selfdestruct + redeploy) murieron.
///   - El compilador emite una advertencia de deprecación (es esperada).
///   - `selfdestruct` sigue forzando ETH a cualquier dirección, aunque no
///     tenga `receive`. Por eso NUNCA confíes en `address(this).balance`
///     como invariante (ver `ForceSendVictim` y su test).
///   Alternativa recomendada para "apagar": un flag `closed` + retirar fondos.
contract Destructible {
    error NotOwner();
    error Closed();

    event Killed(address indexed beneficiary, uint256 amount);

    address public immutable owner;
    /// @notice Dato de estado para comprobar que sobrevive al selfdestruct.
    uint256 public value = 42;
    /// @notice Alternativa moderna: cierre lógico.
    bool public closed;

    constructor() payable {
        owner = msg.sender;
    }

    function ping() external view returns (string memory) {
        if (closed) revert Closed();
        return "sigo vivo";
    }

    /// @notice Autodestruye enviando el ETH a `beneficiary`.
    function kill(address payable beneficiary) external {
        if (msg.sender != owner) revert NotOwner();
        emit Killed(beneficiary, address(this).balance);
        selfdestruct(beneficiary);
    }

    /// @notice Cierre recomendado: marca cerrado y transfiere fondos.
    function close(address payable beneficiary) external {
        if (msg.sender != owner) revert NotOwner();
        closed = true;
        (bool ok,) = beneficiary.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}

/// @notice Fábrica que crea y destruye en la misma transacción (aquí SÍ se borra).
contract SameTxFactory {
    function createAndKill() external payable returns (address d) {
        Destructible x = new Destructible{value: msg.value}();
        x.kill(payable(msg.sender));
        d = address(x);
    }
}

/// @notice Juego vulnerable que asume que solo recibe ETH por `play()`.
/// @dev Invariante rota: `address(this).balance` puede crecer por selfdestruct.
contract ForceSendVictim {
    uint256 public constant TARGET = 3 ether;
    address public winner;

    function play() external payable {
        require(msg.value == 1 ether, "solo 1 ether");
        uint256 bal = address(this).balance;
        require(bal <= TARGET, "juego terminado");
        if (bal == TARGET) winner = msg.sender;
    }
    // Sin receive/fallback: ¡aun así puede recibir ETH forzado!
}

/// @notice Atacante que fuerza ETH a la víctima con selfdestruct.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
