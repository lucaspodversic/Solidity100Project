// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StakingFarm — granja de rewards estilo Synthetix `StakingRewards` (simplificada)
/// @notice Se stakea `stakingToken` y se gana `rewardToken` a una tasa constante por segundo,
///         repartida proporcionalmente al stake. Es la "fuente de rendimiento" que el vault
///         auto-compone. Contabilidad O(1) con `rewardPerToken` acumulado.
contract StakingFarm {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    uint256 public rewardRate; // reward por segundo
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored; // escalado 1e18
    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(IERC20 _staking, IERC20 _reward) {
        stakingToken = _staking;
        rewardToken = _reward;
    }

    function lastTimeApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeApplicable() - lastUpdate) * rewardRate * 1e18) / totalStaked;
    }

    function earned(address a) public view returns (uint256) {
        return rewards[a] + (balanceOf[a] * (rewardPerToken() - userRewardPerTokenPaid[a])) / 1e18;
    }

    modifier update(address a) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdate = lastTimeApplicable();
        if (a != address(0)) {
            rewards[a] = earned(a);
            userRewardPerTokenPaid[a] = rewardPerTokenStored;
        }
        _;
    }

    /// @notice Fondea `amount` de rewards a repartir durante `duration` (sin control de acceso: mock).
    function notifyReward(uint256 amount, uint256 duration) external update(address(0)) {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardRate = amount / duration;
        periodFinish = block.timestamp + duration;
        lastUpdate = block.timestamp;
    }

    function stake(uint256 amount) external update(msg.sender) {
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external update(msg.sender) {
        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
    }

    function getReward() external update(msg.sender) returns (uint256 r) {
        r = rewards[msg.sender];
        if (r > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, r);
        }
    }
}
