// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultV1} from "./VaultV1.sol";

/// @title VaultV2 — Segunda versión: pausa de emergencia + comisión de retiro
/// @notice Hereda TODA la lógica de V1 y agrega funcionalidades.
/// @dev Regla de oro de upgrades: NO reordenar ni borrar campos de almacenamiento.
///      Las variables nuevas van en OTRO namespace ERC-7201 (`VaultV2Ext`), así
///      es imposible pisar los datos de V1.
contract VaultV2 is VaultV1 {
    /// @custom:storage-location erc7201:solidity100.storage.VaultV2Ext
    struct V2Storage {
        bool paused;       // pausa de emergencia
        uint16 feeBps;     // comisión de retiro en basis points (máx 5%)
        uint256 feesAccrued; // comisiones acumuladas para el owner
    }

    bytes32 private constant V2_SLOT =
        keccak256(abi.encode(uint256(keccak256("solidity100.storage.VaultV2Ext")) - 1)) & ~bytes32(uint256(0xff));

    uint16 public constant MAX_FEE_BPS = 500;

    event Paused(bool paused);
    event FeeChanged(uint16 feeBps);

    error IsPaused();
    error FeeTooHigh();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() VaultV1() {}

    function _v2() private pure returns (V2Storage storage $) {
        bytes32 slot = V2_SLOT;
        assembly {
            $.slot := slot
        }
    }

    /// @notice Inicializador de la migración a V2 (versión 2 del Initializable).
    /// @dev `reinitializer(2)` permite correr UNA vez código de migración al
    ///      actualizar con `upgradeToAndCall(v2, abi.encodeCall(initializeV2, (fee)))`.
    function initializeV2(uint16 feeBps) external reinitializer(2) onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        _v2().feeBps = feeBps;
        emit FeeChanged(feeBps);
    }

    /// @notice Pausa o reanuda retiros (solo owner).
    function setPaused(bool p) external onlyOwner {
        _v2().paused = p;
        emit Paused(p);
    }

    /// @notice Cambia la comisión (acotada a MAX_FEE_BPS para proteger usuarios).
    function setFee(uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        _v2().feeBps = feeBps;
        emit FeeChanged(feeBps);
    }

    /// @notice Retiro con comisión y respetando la pausa.
    function withdraw(uint256 amount) external override {
        V2Storage storage v = _v2();
        if (v.paused) revert IsPaused();
        VaultStorage storage $ = _s();
        if ($.balances[msg.sender] < amount) revert InsufficientBalance();
        uint256 fee = (amount * v.feeBps) / 10_000;
        $.balances[msg.sender] -= amount;
        $.totalDeposits -= amount;
        v.feesAccrued += fee;
        (bool ok,) = msg.sender.call{value: amount - fee}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice El owner cobra las comisiones acumuladas.
    function claimFees() external onlyOwner {
        uint256 f = _v2().feesAccrued;
        _v2().feesAccrued = 0;
        (bool ok,) = msg.sender.call{value: f}("");
        if (!ok) revert TransferFailed();
    }

    function paused() external view returns (bool) { return _v2().paused; }
    function feeBps() external view returns (uint16) { return _v2().feeBps; }
    function feesAccrued() external view returns (uint256) { return _v2().feesAccrued; }

    function version() external pure override returns (string memory) {
        return "2.0.0";
    }
}
