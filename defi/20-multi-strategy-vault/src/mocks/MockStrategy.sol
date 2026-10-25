// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../IStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockStrategy — estrategia simulada con APY configurable, ganancias y pérdidas manuales
/// @notice Solo guarda el asset; `simulateGain` acuña tokens (rendimiento) y `simulateLoss`
///         los manda a una dirección "quemada" (hackeo, slashing, mala deuda...).
///         `liquidityCap` simula iliquidez: no puede devolver más de eso por llamada.
contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable override asset;
    address public immutable vault;
    uint256 public override apyBps;
    uint256 public liquidityCap = type(uint256).max;

    error OnlyVault();

    constructor(address _asset, address _vault, uint256 _apy) {
        asset = _asset;
        vault = _vault;
        apyBps = _apy;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function invest(uint256) external view override {
        if (msg.sender != vault) revert OnlyVault();
        // nada que hacer: el dinero queda en este contrato
    }

    function divest(uint256 amount) external override returns (uint256 sent) {
        if (msg.sender != vault) revert OnlyVault();
        uint256 bal = totalAssets();
        sent = amount < bal ? amount : bal;
        if (sent > liquidityCap) sent = liquidityCap;
        IERC20(asset).safeTransfer(vault, sent);
    }

    // ----- controles de test -----
    function setApy(uint256 a) external { apyBps = a; }
    function setLiquidityCap(uint256 c) external { liquidityCap = c; }
    function simulateGain(uint256 a) external { MockERC20(asset).mint(address(this), a); }
    function simulateLoss(uint256 a) external { IERC20(asset).safeTransfer(address(0xdead), a); }
}
