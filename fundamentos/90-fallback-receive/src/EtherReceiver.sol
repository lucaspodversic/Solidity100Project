// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EtherReceiver — cómo un contrato recibe ETH y llamadas desconocidas
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #90
/// @notice Árbol de decisión de la EVM cuando llega una llamada:
///
///            ¿msg.data está vacío?
///              /              \
///            sí                no
///            /                   \
///    ¿existe receive()?     ¿coincide el selector con alguna función?
///      /        \                /          \
///    sí         no             sí            no
///    |           |             |              |
///  receive()  fallback()   esa función     fallback()
///
/// @dev Detalles importantes:
///   - `receive()` debe ser `external payable` y no toma argumentos.
///   - `fallback()` puede ser payable o no; si no lo es y llega ETH, revierte.
///   - `transfer`/`send` reenvían solo 2300 gas: un receive que escribe
///     storage FALLA con ellos. Por eso se recomienda `call{value:}`.
contract EtherReceiver {
    event Received(address indexed from, uint256 amount, uint256 gasLeft);
    event FallbackCalled(address indexed from, uint256 amount, bytes data);

    /// @notice Contadores para que los tests verifiquen qué función corrió.
    uint256 public receiveCount;
    uint256 public fallbackCount;
    /// @notice Último calldata recibido por fallback.
    bytes public lastData;

    /// @notice Se ejecuta con ETH y calldata vacío.
    /// @dev Escribe storage (~22k gas) a propósito: falla con transfer/send.
    receive() external payable {
        receiveCount++;
        emit Received(msg.sender, msg.value, gasleft());
    }

    /// @notice Se ejecuta con calldata que no coincide con ninguna función.
    /// @dev Variante con parámetros (desde 0.7.6): recibe el calldata crudo y
    ///      puede devolver bytes arbitrarios. Útil en proxies (ver #95).
    fallback(bytes calldata data) external payable returns (bytes memory) {
        fallbackCount++;
        lastData = data;
        emit FallbackCalled(msg.sender, msg.value, data);
        return abi.encode("fallback ok");
    }

    /// @notice Función normal para contrastar.
    function hello() external pure returns (string memory) {
        return "hola";
    }
}

/// @notice Contrato que solo tiene fallback NO payable: rechaza ETH.
contract NoEtherAccepted {
    uint256 public calls;
    fallback() external {
        calls++;
    }
}

/// @notice Remitente que prueba las tres formas de enviar ETH.
contract Sender {
    /// @notice `transfer`: 2300 gas, revierte si falla.
    function viaTransfer(address payable to) external payable {
        to.transfer(msg.value);
    }

    /// @notice `send`: 2300 gas, devuelve bool (¡hay que chequearlo!).
    function viaSend(address payable to) external payable returns (bool ok) {
        ok = to.send(msg.value);
    }

    /// @notice `call`: reenvía todo el gas disponible; forma recomendada.
    function viaCall(address payable to) external payable returns (bool ok) {
        (ok,) = to.call{value: msg.value}("");
    }
}
