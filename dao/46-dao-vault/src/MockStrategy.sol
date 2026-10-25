// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategy} from "./DAOVault.sol";
contract MockStrategy is IStrategy {
    IERC20 public immutable asset;
    uint256 public managed;
    constructor(address a) { asset = IERC20(a); }
    function invest(uint256 amount) external override { managed += amount; }
    function divest(uint256 amount) external override returns (uint256) {
        uint256 out = amount > managed ? managed : amount;
        managed -= out;
        asset.transfer(msg.sender, out);
        return out;
    }
    function totalManaged() external view override returns (uint256) { return managed; }
}
