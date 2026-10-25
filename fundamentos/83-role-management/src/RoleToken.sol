// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title RoleToken — ERC20 con roles admin / minter / pauser
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #83
/// @notice Separación de privilegios (principio de menor privilegio):
///   - `DEFAULT_ADMIN_ROLE`: otorga y revoca roles. No acuña ni pausa por sí.
///   - `MINTER_ROLE`: puede acuñar tokens.
///   - `PAUSER_ROLE`: puede pausar/despausar transferencias.
/// @dev Usa `AccessControl` de OpenZeppelin: cada rol es un `bytes32`
///      (hash de su nombre) con un "rol administrador" que lo gestiona.
///      Si se compromete una clave de minter, el admin la revoca sin
///      afectar al resto del sistema.
contract RoleToken is ERC20, AccessControl, Pausable {
    /// @notice Identificador del rol que acuña. keccak256 evita colisiones.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice Identificador del rol que pausa.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @param admin Cuenta que recibe el rol de administrador (ideal: multisig).
    constructor(address admin) ERC20("Role Token", "ROLE") {
        // Solo el admin al inicio; él decide quién acuña y quién pausa.
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Acuñar tokens. Requiere MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Pausar transferencias. Requiere PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Reanudar transferencias. Requiere PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev Hook central de OZ v5: toda transferencia, mint y burn pasa por
    ///      `_update`, así que bloquearlo aquí pausa todo el movimiento.
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }
}
