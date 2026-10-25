// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UpgradeableTokenV1} from "./UpgradeableTokenV1.sol";

/// @title UpgradeableTokenV2 — nueva lógica: quema y tope de suministro
/// @notice Hereda V1 (mismo layout) y agrega funcionalidad. El estado nuevo
///         (`cap`) se guarda en OTRO namespace ERC-7201 para no tocar el de V1.
/// @dev `initializeV2` usa `reinitializer(2)`: corre una sola vez, después
///      del upgrade, y no puede re-ejecutarse.
contract UpgradeableTokenV2 is UpgradeableTokenV1 {
    error CapExceeded(uint256 cap, uint256 nuevoTotal);

    /// @custom:storage-location erc7201:fundamentos.storage.UpgradeableTokenV2
    struct V2Storage {
        uint256 cap;
    }

    /// @dev Slot ERC-7201 de "fundamentos.storage.UpgradeableTokenV2" (verificado en tests).
    bytes32 internal constant V2_STORAGE_SLOT = 0x5075c39e66d6f0232c0acd6c5eb977de01db2fdaa7bca08eb1fbaf15a4ff6700;

    function _v2() internal pure returns (V2Storage storage $) {
        assembly {
            $.slot := V2_STORAGE_SLOT
        }
    }

    /// @notice Inicialización de la versión 2 (fija el tope).
    function initializeV2(uint256 cap_) external reinitializer(2) onlyOwner {
        _v2().cap = cap_;
    }

    function cap() external view returns (uint256) {
        return _v2().cap;
    }

    function version() external pure override returns (string memory) {
        return "2";
    }

    /// @notice Nueva función: cualquiera quema sus propios tokens.
    function burn(uint256 value) external {
        TokenStorage storage $ = _s();
        uint256 b = $.balances[msg.sender];
        if (b < value) revert InsufficientBalance(b, value);
        $.balances[msg.sender] = b - value;
        $.totalSupply -= value;
        emit Transfer(msg.sender, address(0), value);
    }

    /// @notice Acuñar respetando el tope (envuelve la lógica de V1).
    function mintCapped(address to, uint256 value) external onlyOwner {
        uint256 nuevo = _s().totalSupply + value;
        if (nuevo > _v2().cap) revert CapExceeded(_v2().cap, nuevo);
        _mint(to, value);
    }
}
