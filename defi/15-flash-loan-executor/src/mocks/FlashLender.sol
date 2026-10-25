// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FlashLender — prestamista ERC-3156 mínimo (simula Aave/Balancer en local)
/// @notice Presta cualquier token que tenga en balance; cobra `feeBps` (ej. 9 = 0,09 %).
contract FlashLender is IERC3156FlashLender {
    using SafeERC20 for IERC20;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 public immutable feeBps;

    error CallbackFailed();
    error NotRepaid();

    constructor(uint256 _feeBps) {
        feeBps = _feeBps;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function flashFee(address, uint256 amount) public view returns (uint256) {
        return (amount * feeBps) / 10_000;
    }

    /// @notice Transfiere `amount`, llama al callback y cobra `amount + fee` con transferFrom.
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        uint256 fee = flashFee(token, amount);
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(address(receiver), amount);
        if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) != CALLBACK_SUCCESS) revert CallbackFailed();
        IERC20(token).safeTransferFrom(address(receiver), address(this), amount + fee);
        if (IERC20(token).balanceOf(address(this)) < balBefore + fee) revert NotRepaid();
        return true;
    }
}
