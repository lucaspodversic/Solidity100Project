// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LendingPool} from "../src/protocol/LendingPool.sol";
import {JumpRateModel} from "../src/protocol/JumpRateModel.sol";
import {PriceOracle} from "../src/protocol/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {FlashLender} from "../src/mocks/FlashLender.sol";
import {OracleDex} from "../src/mocks/OracleDex.sol";
import {LiquidationBot} from "../src/LiquidationBot.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

/// @title Tests del bot de liquidación
contract LiquidationBotTest is Test {
    LendingPool pool;
    PriceOracle oracle;
    MockERC20 usdc;
    MockERC20 weth;
    FlashLender fl;
    OracleDex dex;
    LiquidationBot bot;

    address lender = makeAddr("lender");
    address alice = makeAddr("alice"); // 10 ETH, debe 15000
    address bob = makeAddr("bob"); // 10 ETH, debe 5000 (sana)
    address carol = makeAddr("carol"); // 1 ETH, debe 1500 (chica)
    address operator = makeAddr("operator");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        oracle = new PriceOracle();
        _price(2000e18);
        JumpRateModel m = new JumpRateModel(0, 0.04e18, 0.75e18, 0.8e18);
        pool = new LendingPool(oracle, makeAddr("treasury"));
        pool.listMarket(address(weth), 0.75e18, 0.8e18, 0.05e18, 0.1e18, m);
        pool.listMarket(address(usdc), 0.8e18, 0.85e18, 0.05e18, 0.1e18, m);

        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 1_000_000e6);
        vm.stopPrank();
        _open(alice, 10e18, 15_000e6);
        _open(bob, 10e18, 5_000e6);
        _open(carol, 1e18, 1_500e6);

        fl = new FlashLender(9);
        usdc.mint(address(fl), 1_000_000e6);
        dex = new OracleDex(oracle);
        usdc.mint(address(dex), 1_000_000e6);
        weth.mint(address(dex), 1_000e18);

        vm.prank(operator);
        bot = new LiquidationBot(pool, fl, dex);
    }

    function _price(uint256 p) internal {
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), p);
    }

    function _open(address u, uint256 coll, uint256 debt) internal {
        weth.mint(u, coll);
        vm.startPrank(u);
        weth.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), coll);
        pool.borrow(address(usdc), debt);
        vm.stopPrank();
    }

    function _users() internal view returns (address[] memory us) {
        us = new address[](3);
        us[0] = alice;
        us[1] = bob;
        us[2] = carol;
    }

    function _params(address u, uint256 repay, uint256 minProfit) internal view returns (LiquidationBot.Params memory) {
        return LiquidationBot.Params(u, address(usdc), address(weth), repay, minProfit);
    }

    function test_ScanFindsOnlyUnhealthy() public {
        _price(1800e18);
        LiquidationBot.Opportunity[] memory ops = bot.scan(_users(), address(usdc), address(weth));
        assertLt(ops[0].healthFactor, 1e18);
        assertGt(ops[0].estProfit, 0);
        assertEq(ops[1].repayAmount, 0, "bob sana");
        assertLt(ops[2].healthFactor, 1e18);
        assertEq(ops[0].repayAmount, 7_500e6);
        // 7500·1,05/1800 = 4,375 ETH
        assertApproxEqAbs(ops[0].expectedSeized, 4.375e18, 1e12);
    }

    function test_ProfitableLiquidationWithZeroCapital() public {
        _price(1800e18);
        assertEq(usdc.balanceOf(address(bot)), 0);
        vm.prank(operator);
        uint256 profit = bot.execute(_params(alice, 7_500e6, 300e6));
        // 4,375·1800·0,997 − 7500 − 6,75 = 344,6 USDC
        assertApproxEqRel(profit, 344.625e6, 0.001e18);
        assertEq(usdc.balanceOf(operator), profit);
        assertEq(usdc.balanceOf(address(bot)), 0);
        assertEq(weth.balanceOf(address(bot)), 0);
        assertGt(pool.healthFactor(alice), 1e18, "posicion saneada");
    }

    function test_ScanMatchesExecution() public {
        _price(1800e18);
        LiquidationBot.Opportunity[] memory ops = bot.scan(_users(), address(usdc), address(weth));
        vm.prank(operator);
        uint256 profit = bot.execute(_params(alice, ops[0].repayAmount, 0));
        assertApproxEqRel(int256(profit), ops[0].estProfit, 0.001e18);
    }

    function test_RevertsIfBelowMinProfit() public {
        _price(1800e18);
        vm.prank(operator);
        vm.expectRevert();
        bot.execute(_params(alice, 7_500e6, 1_000e6));
    }

    function test_RevertsWhenDexSlippageEatsBonus() public {
        _price(1800e18);
        dex.setSlippage(500); // 5 % + 0,3 % fee > 5 % bonus
        LiquidationBot.Opportunity[] memory ops = bot.scan(_users(), address(usdc), address(weth));
        assertLt(ops[0].estProfit, 0, "scan detecta no rentable");
        vm.prank(operator);
        vm.expectRevert(OracleDex.Slippage.selector);
        bot.execute(_params(alice, 7_500e6, 0));
    }

    function test_HealthyPositionReverts() public {
        vm.prank(operator);
        vm.expectRevert(LendingPool.HealthyPosition.selector);
        bot.execute(_params(bob, 1_000e6, 0));
    }

    function test_OnlyOwner() public {
        _price(1800e18);
        vm.prank(alice);
        vm.expectRevert();
        bot.execute(_params(alice, 7_500e6, 0));
    }

    function test_CallbackRejectsForeignCallers() public {
        bytes memory data = abi.encode(_params(alice, 1, 0));
        vm.expectRevert(LiquidationBot.UntrustedLender.selector);
        bot.onFlashLoan(address(bot), address(usdc), 1, 0, data);
        // Alguien llama al lender real apuntando al bot como receptor
        vm.expectRevert(LiquidationBot.UntrustedInitiator.selector);
        fl.flashLoan(IERC3156FlashBorrower(address(bot)), address(usdc), 1e6, data);
    }

    function test_LiquidateMultipleSequentially() public {
        _price(1800e18);
        vm.startPrank(operator);
        bot.execute(_params(alice, 7_500e6, 0));
        bot.execute(_params(carol, 750e6, 0));
        vm.stopPrank();
        assertGt(usdc.balanceOf(operator), 360e6);
    }

    function test_Sweep() public {
        usdc.mint(address(bot), 5e6);
        vm.prank(operator);
        bot.sweep(address(usdc));
        assertEq(usdc.balanceOf(operator), 5e6);
    }

    /// @notice Fuzz: para cualquier caída de precio que vuelva liquidable a alice (pero sin
    ///         insolvencia profunda), el bot nunca termina con pérdida: o gana o revierte.
    function testFuzz_NeverLoses(uint256 price) public {
        price = bound(price, 1500e18, 1870e18);
        _price(price);
        LiquidationBot.Opportunity[] memory ops = bot.scan(_users(), address(usdc), address(weth));
        vm.prank(operator);
        try bot.execute(_params(alice, ops[0].repayAmount, 0)) returns (uint256 profit) {
            assertGe(usdc.balanceOf(operator), profit);
        } catch {}
        assertEq(usdc.balanceOf(address(bot)), 0);
    }
}
