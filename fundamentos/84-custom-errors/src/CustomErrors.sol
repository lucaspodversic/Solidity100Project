// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Errores personalizados vs `require` con string
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #84
/// @notice Dos bancos idénticos: uno usa `require(cond, "mensaje")` y otro
///         `if (!cond) revert ErrorPersonalizado(args)`. Los tests miden el
///         gas de despliegue y de las reversiones.
/// @dev ¿Por qué los errores personalizados ahorran gas?
///   - Un string se guarda en el bytecode y, al revertir, se ABI-codifica
///     completo como `Error(string)` (selector + offset + longitud + datos).
///   - Un error personalizado se identifica con 4 bytes (su selector) más
///     los argumentos que quieras: bytecode más chico y revert más barato.
///   - Además los argumentos dan **contexto** (cuánto faltó, quién llamó)
///     que un string fijo no puede dar.
///   Desde Solidity 0.8.26 existe `require(cond, ErrorPersonalizado())`;
///   aquí usamos `if/revert` para compatibilidad con ^0.8.20.

/// @notice Error a nivel de archivo: puede reutilizarse en varios contratos.
error Unauthorized(address caller);

/// @notice Versión con strings (la "clásica").
contract BankWithStrings {
    address public owner = msg.sender;
    mapping(address => uint256) public balances;

    function deposit() external payable {
        require(msg.value > 0, "BankWithStrings: el deposito debe ser mayor a cero");
        balances[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "BankWithStrings: saldo insuficiente para retirar");
        balances[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "BankWithStrings: fallo la transferencia de ETH");
    }

    function adminOnly() external view {
        require(msg.sender == owner, "BankWithStrings: solo el owner puede llamar");
    }
}

/// @notice Versión con errores personalizados (la recomendada).
contract BankWithCustomErrors {
    /// @notice Depósito de cero.
    error ZeroDeposit();
    /// @notice Saldo insuficiente: indicamos cuánto había y cuánto se pidió.
    error InsufficientBalance(uint256 disponible, uint256 solicitado);
    /// @notice Falló la transferencia de ETH.
    error TransferFailed();

    address public owner = msg.sender;
    mapping(address => uint256) public balances;

    function deposit() external payable {
        if (msg.value == 0) revert ZeroDeposit();
        balances[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        uint256 bal = balances[msg.sender];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        balances[msg.sender] = bal - amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function adminOnly() external view {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
    }
}
