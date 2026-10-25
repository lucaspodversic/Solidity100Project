// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DAOVault — vault DeFi cuyos parámetros controla una DAO (owner)
/// @author Proyecto 46
/// @notice Depósitos/retiros de un ERC20. Fee de performance y cap los setea el
///         `governor` (en prod: Timelock/Governor). Upgrade vía patrón de lógica
///         intercambiable (`strategy`) que el governor puede apuntar.
interface IStrategy {
    function invest(uint256 amount) external;
    function divest(uint256 amount) external returns (uint256);
    function totalManaged() external view returns (uint256);
}

contract DAOVault is ReentrancyGuard {
    IERC20 public immutable asset;
    address public governor;
    IStrategy public strategy;
    uint256 public feeBps;       // fee sobre yield
    uint256 public depositCap;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    event Deposit(address u, uint256 assets, uint256 minted);
    event Withdraw(address u, uint256 assets, uint256 burned);
    event Params(uint256 feeBps, uint256 cap);
    event StrategySet(address s);
    event GovernorSet(address g);

    error OnlyGov(); error Cap(); error Zero();

    modifier onlyGov() { if (msg.sender != governor) revert OnlyGov(); _; }

    constructor(address asset_, address governor_, uint256 feeBps_, uint256 cap_) {
        asset = IERC20(asset_);
        governor = governor_;
        feeBps = feeBps_;
        depositCap = cap_;
    }

    function totalAssets() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        if (address(strategy) != address(0)) bal += strategy.totalManaged();
        return bal;
    }

    function deposit(uint256 amount) external nonReentrant returns (uint256 minted) {
        if (amount == 0) revert Zero();
        if (totalAssets() + amount > depositCap) revert Cap();
        uint256 ta = totalAssets();
        minted = totalShares == 0 ? amount : (amount * totalShares) / ta;
        shares[msg.sender] += minted;
        totalShares += minted;
        require(asset.transferFrom(msg.sender, address(this), amount), "tf");
        emit Deposit(msg.sender, amount, minted);
    }

    function withdraw(uint256 shareAmount) external nonReentrant returns (uint256 assetsOut) {
        if (shareAmount == 0 || shares[msg.sender] < shareAmount) revert Zero();
        assetsOut = (totalAssets() * shareAmount) / totalShares;
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        uint256 bal = asset.balanceOf(address(this));
        if (assetsOut > bal && address(strategy) != address(0)) {
            strategy.divest(assetsOut - bal);
        }
        require(asset.transfer(msg.sender, assetsOut), "tf");
        emit Withdraw(msg.sender, assetsOut, shareAmount);
    }

    function setParams(uint256 feeBps_, uint256 cap_) external onlyGov {
        require(feeBps_ <= 2000, "fee");
        feeBps = feeBps_;
        depositCap = cap_;
        emit Params(feeBps_, cap_);
    }

    function setStrategy(address s) external onlyGov {
        strategy = IStrategy(s);
        emit StrategySet(s);
    }

    function setGovernor(address g) external onlyGov {
        governor = g;
        emit GovernorSet(g);
    }

    /// @notice El governor puede empujar idle funds a la strategy.
    function allocate(uint256 amount) external onlyGov {
        require(asset.transfer(address(strategy), amount), "tf");
        strategy.invest(amount);
    }
}
