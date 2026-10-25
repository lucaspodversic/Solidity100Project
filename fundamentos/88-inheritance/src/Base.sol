// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Bloques base para demostrar herencia
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #88
/// @notice Conceptos: contratos abstractos, `virtual`/`override`, `super`,
///         herencia múltiple y linealización C3, constructores en cadena.

/// @notice Módulo de propiedad. `abstract` porque no tiene sentido desplegarlo solo.
abstract contract Owned {
    error NotOwner();
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Nombre del módulo; `virtual` permite sobrescribirlo.
    function describe() public pure virtual returns (string memory) {
        return "Owned";
    }
}

/// @notice Módulo de registro de acciones (hereda de Owned).
abstract contract Logger is Owned {
    event Log(string message);
    /// @notice Cantidad de logs emitidos.
    uint256 public logCount;

    function _log(string memory m) internal {
        logCount++;
        emit Log(m);
    }

    function describe() public pure virtual override returns (string memory) {
        return string.concat("Logger>", super.describe());
    }
}

/// @notice Módulo de límite de operaciones (también hereda de Owned).
abstract contract Limited is Owned {
    error LimitExceeded();
    uint256 public immutable maxOps;
    uint256 public ops;

    constructor(uint256 maxOps_) {
        maxOps = maxOps_;
    }

    /// @dev Función abstracta: cada hijo decide qué es "una operación".
    function _beforeOp() internal virtual {
        if (++ops > maxOps) revert LimitExceeded();
    }

    function describe() public pure virtual override returns (string memory) {
        return string.concat("Limited>", super.describe());
    }
}
