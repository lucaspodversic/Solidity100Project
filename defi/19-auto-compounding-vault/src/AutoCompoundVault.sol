// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StakingFarm} from "./mocks/StakingFarm.sol";
import {SimpleAMM} from "./mocks/SimpleAMM.sol";

/// @title AutoCompoundVault — vault ERC-4626 que re-invierte automáticamente los rewards
/// @notice Los usuarios depositan el token de stake; el vault lo stakea en la granja.
///         `harvest()` (permisionless) reclama los rewards, los vende por más token de stake
///         en un AMM y los re-stakea: el precio por share sube y el interés se COMPONE.
///         Quien llama a `harvest` cobra una recompensa (bounty) por pagar el gas.
/// @dev Defensa anti-sandwich: la ganancia de cada harvest se libera **linealmente** durante
///      `LOCK_PERIOD`. Sin esto, un atacante podría depositar justo antes del harvest,
///      capturar parte del salto de precio y retirar justo después.
contract AutoCompoundVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    /// @notice Duración del desbloqueo lineal de cada ganancia.
    uint256 public constant LOCK_PERIOD = 6 hours;

    StakingFarm public immutable farm;
    IERC20 public immutable reward;
    SimpleAMM public immutable amm;

    address public treasury;
    uint256 public bountyBps = 50; // 0,5 % de la ganancia al caller
    uint256 public perfFeeBps = 1_000; // 10 % al tesoro

    /// @notice Ganancia aún bloqueada al momento del último harvest.
    uint256 public lockedProfit;
    /// @notice Timestamp del último harvest.
    uint256 public lastHarvest;

    event Harvested(address indexed caller, uint256 rewards, uint256 profit, uint256 bounty, uint256 fee);

    error NothingToHarvest();
    error BadFee();

    constructor(IERC20 asset_, StakingFarm _farm, SimpleAMM _amm, address _treasury)
        ERC20("Auto-compound STK", "acSTK")
        ERC4626(asset_)
        Ownable(msg.sender)
    {
        farm = _farm;
        reward = _farm.rewardToken();
        amm = _amm;
        treasury = _treasury;
        asset_.forceApprove(address(_farm), type(uint256).max);
        reward.forceApprove(address(_amm), type(uint256).max);
    }

    /// @notice Ganancia todavía bloqueada (decrece linealmente a 0 en LOCK_PERIOD).
    function lockedNow() public view returns (uint256) {
        uint256 dt = block.timestamp - lastHarvest;
        if (dt >= LOCK_PERIOD) return 0;
        return (lockedProfit * (LOCK_PERIOD - dt)) / LOCK_PERIOD;
    }

    /// @notice Activos = stakeado + ocioso − ganancia aún bloqueada.
    function totalAssets() public view override returns (uint256) {
        return farm.balanceOf(address(this)) + IERC20(asset()).balanceOf(address(this)) - lockedNow();
    }

    /// @notice Rewards pendientes y su valor estimado en asset (para bots de harvest).
    function pendingHarvest() external view returns (uint256 rewards, uint256 assetsOut) {
        rewards = farm.earned(address(this));
        assetsOut = rewards == 0 ? 0 : amm.getAmountOut(address(reward), rewards);
    }

    /// @notice Reclama, vende y re-stakea. `minOut` protege contra sandwich del swap.
    function harvest(uint256 minOut) external nonReentrant returns (uint256 profit) {
        uint256 r = farm.getReward();
        if (r == 0) revert NothingToHarvest();
        uint256 out = amm.swap(address(reward), r, minOut, address(this));
        uint256 bounty = (out * bountyBps) / BPS;
        uint256 fee = (out * perfFeeBps) / BPS;
        profit = out - bounty - fee;
        IERC20 a = IERC20(asset());
        if (bounty > 0) a.safeTransfer(msg.sender, bounty);
        if (fee > 0) a.safeTransfer(treasury, fee); // fee en asset (simple y transparente)
        // La ganancia nueva se suma a lo que quedaba bloqueado y se re-bloquea completa.
        lockedProfit = lockedNow() + profit;
        lastHarvest = block.timestamp;
        farm.stake(a.balanceOf(address(this)));
        emit Harvested(msg.sender, r, profit, bounty, fee);
    }

    /// @dev Tras cobrar el depósito, stakea todo el saldo ocioso.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        farm.stake(assets);
    }

    /// @dev Antes de pagar, des-stakea lo que falte.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) farm.withdraw(assets - idle);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function setFees(uint256 bounty, uint256 perf, address _treasury) external onlyOwner {
        if (bounty > 300 || perf > 2_000) revert BadFee();
        bountyBps = bounty;
        perfFeeBps = perf;
        treasury = _treasury;
    }
}
