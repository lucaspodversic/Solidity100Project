// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title NotUUPS — implementación SIN soporte UUPS (para tests negativos)
/// @notice Si el proxy se actualizara a esto, quedaría congelado para siempre
///         porque no tiene `upgradeToAndCall`. `UUPSUpgradeable` lo impide al
///         exigir que la nueva implementación devuelva el `proxiableUUID` correcto.
contract NotUUPS {
    function version() external pure returns (string memory) {
        return "rota";
    }
}
