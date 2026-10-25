// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool, IERC3156FlashBorrower} from "./LendingPool.sol";
import {MockDex, MockToken} from "./Mocks.sol";

/// @title LiquidationBot — Liquida sin capital propio usando un flash loan
/// @notice 1) flash loan de DAI, 2) liquida, 3) vende el WETH recibido, 4) devuelve DAI + fee,
///         5) se queda con la ganancia (bonus − fee − slippage).
contract LiquidationBot is IERC3156FlashBorrower {
    LendingPool public immutable pool;
    MockDex public immutable dex;
    address public immutable owner;

    constructor(LendingPool _pool, MockDex _dex) {
        pool = _pool;
        dex = _dex;
        owner = msg.sender;
    }

    function run(address victim, uint256 repayAmount) external {
        require(msg.sender == owner, "solo owner");
        pool.flashLoan(this, address(pool.asset()), repayAmount, abi.encode(victim));
        // la ganancia queda en el bot; se la enviamos al owner
        IERC20 a = pool.asset();
        a.transfer(owner, a.balanceOf(address(this)));
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        // solo el pool, y solo si lo iniciamos nosotros (evita que terceros nos usen)
        require(msg.sender == address(pool) && initiator == address(this), "callback no autorizado");
        address victim = abi.decode(data, (address));
        IERC20(token).approve(address(pool), type(uint256).max);
        uint256 seized = pool.liquidate(victim, amount);
        IERC20 coll = pool.collateralToken();
        coll.approve(address(dex), seized);
        dex.sell(coll, MockToken(token), seized);
        // allowance para que el pool cobre amount + fee
        require(IERC20(token).balanceOf(address(this)) >= amount + fee, "no rentable");
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
