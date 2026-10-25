// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title VendorToken — ERC20 simple que se vende a través del Vendor
/// @notice Se acuña todo el suministro inicial a quien despliega; luego ese
///         dueño transfiere el inventario al contrato `Vendor`.
/// @dev Usamos la implementación auditada de OpenZeppelin v5 (no reinventar
///      la rueda en contratos de tokens).
contract VendorToken is ERC20 {
    /// @param initialSupply Suministro inicial con 18 decimales.
    constructor(uint256 initialSupply) ERC20("Vendor Token", "VND") {
        _mint(msg.sender, initialSupply);
    }
}
