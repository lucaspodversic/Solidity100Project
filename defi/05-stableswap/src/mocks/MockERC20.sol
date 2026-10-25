// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Token ERC-20 de prueba con `mint` libre. SOLO para tests: cualquiera puede acuñar.
/// @dev Permite configurar los decimales para probar pares con tokens de distinta precisión.
contract MockERC20 is ERC20 {
    /// @dev Decimales configurables (por defecto ERC20 de OZ usa 18).
    uint8 private immutable _dec;

    /// @param n Nombre del token.
    /// @param s Símbolo del token.
    /// @param d Cantidad de decimales.
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _dec;
    }

    /// @notice Acuña `amt` tokens a `to`. Sin control de acceso a propósito (mock).
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}
