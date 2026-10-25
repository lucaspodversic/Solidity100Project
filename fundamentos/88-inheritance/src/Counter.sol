// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Owned, Logger, Limited} from "./Base.sol";

/// @title ModularCounter — contador que compone tres módulos por herencia
/// @notice Orden de herencia `Logger, Limited`: Solidity linealiza (C3) como
///         ModularCounter -> Limited -> Logger -> Owned. Por eso `super`
///         dentro de Limited llama a Logger, y en Logger llama a Owned.
///         `describe()` devuelve "Counter>Limited>Logger>Owned".
/// @dev Regla: listar los padres del "más base" al "más derivado".
contract ModularCounter is Logger, Limited {
    uint256 public count;

    /// @dev Los constructores de los padres se invocan explícitamente.
    ///      Se ejecutan en orden de linealización (Owned primero).
    constructor(uint256 maxOps_) Owned(msg.sender) Limited(maxOps_) {}

    /// @notice Incrementa respetando el límite y registrando el evento.
    function increment() external onlyOwner {
        _beforeOp();
        count++;
        _log("increment");
    }

    /// @notice Al sobrescribir en herencia múltiple hay que listar todos los
    ///         padres que definen la función: `override(Logger, Limited)`.
    function describe() public pure override(Logger, Limited) returns (string memory) {
        return string.concat("Counter>", super.describe());
    }
}

/// @title UnlimitedCounter — reusa módulos sobrescribiendo un hook
/// @notice Muestra cómo un hijo cambia el comportamiento de un `virtual`.
contract UnlimitedCounter is Limited {
    uint256 public count;

    constructor() Owned(msg.sender) Limited(0) {}

    /// @dev Desactiva el límite: no llama a super, solo cuenta.
    function _beforeOp() internal override {
        ops++;
    }

    function increment() external {
        _beforeOp();
        count++;
    }
}
