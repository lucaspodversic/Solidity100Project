// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableSwapPool} from "../src/StableSwapPool.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests del pool StableSwap (3pool: USDC 6 dec, USDT 6 dec, DAI 18 dec)
contract StableSwapPoolTest is Test {
    StableSwapPool pool;
    MockERC20 usdc;
    MockERC20 usdt;
    MockERC20 dai;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        usdt = new MockERC20("USDT", "USDT", 6);
        dai = new MockERC20("DAI", "DAI", 18);
        IERC20[] memory cs = new IERC20[](3);
        cs[0] = IERC20(address(usdc));
        cs[1] = IERC20(address(usdt));
        cs[2] = IERC20(address(dai));
        pool = new StableSwapPool(cs, 200, 4e6, "3pool LP", "3CRV"); // A=200, fee 0,04%
        _fund(lp);
        _fund(trader);
        uint256[] memory amts = new uint256[](3);
        amts[0] = 1_000_000e6;
        amts[1] = 1_000_000e6;
        amts[2] = 1_000_000e18;
        vm.prank(lp);
        pool.addLiquidity(amts, 0);
    }

    function _fund(address u) internal {
        usdc.mint(u, 10_000_000e6);
        usdt.mint(u, 10_000_000e6);
        dai.mint(u, 10_000_000e18);
        vm.startPrank(u);
        usdc.approve(address(pool), type(uint256).max);
        usdt.approve(address(pool), type(uint256).max);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function test_InitialMintEqualsD() public view {
        // Pool balanceado: D = suma = 3M (en 18 decimales)
        assertApproxEqAbs(pool.totalSupply(), 3_000_000e18, 1e6);
        assertApproxEqAbs(pool.getVirtualPrice(), 1e18, 1e6);
    }

    function test_SwapNearPegHasTinySlippage() public {
        vm.prank(trader);
        uint256 dy = pool.exchange(0, 1, 10_000e6, 0);
        // 10k USDC -> ~9996 USDT (solo la comisión de 0,04%)
        assertApproxEqRel(dy, 9_996e6, 0.0005e18);
    }

    function test_StableswapBeatsConstantProduct() public view {
        uint256 dy = pool.getDy(0, 1, 100_000e6);
        // En x·y=k con 1M/1M, 100k compraría ~90.9k (sin fee). StableSwap da mucho más.
        uint256 x = 1_000_000e6;
        uint256 cp = (100_000e6 * x) / (x + 100_000e6);
        assertGt(dy, cp + 8_000e6);
    }

    function test_CrossDecimalsSwap() public {
        vm.prank(trader);
        uint256 dy = pool.exchange(2, 0, 1_000e18, 0); // DAI -> USDC
        assertApproxEqRel(dy, 999.6e6, 0.0005e18);
    }

    function test_ImbalancedPoolHasHigherSlippage() public {
        // Desbalanceamos fuertemente: mucho USDC entra
        vm.prank(trader);
        pool.exchange(0, 1, 900_000e6, 0);
        uint256 dyAfter = pool.getDy(0, 1, 10_000e6);
        assertLt(dyAfter, 9_900e6, "lejos del peg el precio empeora");
        // Y el sentido opuesto ahora paga una prima
        uint256 rev = pool.getDy(1, 0, 10_000e6);
        assertGt(rev, 10_000e6);
    }

    function test_SlippageReverts() public {
        vm.prank(trader);
        vm.expectRevert(StableSwapPool.Slippage.selector);
        pool.exchange(0, 1, 10_000e6, 10_000e6);
    }

    function test_FeesIncreaseVirtualPrice() public {
        uint256 vp0 = pool.getVirtualPrice();
        for (uint256 i; i < 5; i++) {
            vm.startPrank(trader);
            uint256 o = pool.exchange(0, 1, 100_000e6, 0);
            pool.exchange(1, 0, o, 0);
            vm.stopPrank();
        }
        assertGt(pool.getVirtualPrice(), vp0);
    }

    function test_RemoveLiquidityProportional() public {
        uint256 lpBal = pool.balanceOf(lp);
        uint256[] memory mins = new uint256[](3);
        vm.prank(lp);
        uint256[] memory out = pool.removeLiquidity(lpBal / 2, mins);
        assertApproxEqRel(out[0], 500_000e6, 1e12);
        assertApproxEqRel(out[2], 500_000e18, 1e12);
    }

    function test_ImbalancedDepositPaysFee() public {
        // Depositar un solo activo da menos LP que su valor "ideal" (paga comisión).
        uint256[] memory amts = new uint256[](3);
        amts[0] = 100_000e6;
        vm.prank(trader);
        uint256 minted = pool.addLiquidity(amts, 0);
        uint256 value = (minted * pool.getVirtualPrice()) / 1e18;
        assertLt(value, 100_000e18);
        assertGt(value, 99_900e18);
    }

    function test_DepositThenWithdrawOneCoinIsNotFreeSwap() public {
        // Ataque: depositar USDC y retirar USDT en un paso, para esquivar la comisión de swap.
        uint256[] memory amts = new uint256[](3);
        amts[0] = 100_000e6;
        vm.startPrank(trader);
        uint256 minted = pool.addLiquidity(amts, 0);
        uint256 got = pool.removeLiquidityOneCoin(minted, 1, 0);
        vm.stopPrank();
        uint256 viaSwap = pool.getDy(0, 1, 100_000e6);
        assertLe(got, viaSwap + 100e6, "no es mas barato que un swap normal");
        assertLt(got, 100_000e6);
    }

    function test_RampA() public {
        vm.expectRevert(StableSwapPool.BadRamp.selector);
        pool.rampA(5000, block.timestamp + 2 days); // >10x
        pool.rampA(1000, block.timestamp + 10 days);
        vm.warp(block.timestamp + 5 days);
        assertEq(pool.A(), 600);
        vm.warp(block.timestamp + 6 days);
        assertEq(pool.A(), 1000);
    }

    function test_OnlyOwnerRamp() public {
        vm.prank(trader);
        vm.expectRevert();
        pool.rampA(400, block.timestamp + 2 days);
    }

    /// @notice Fuzz: un swap de ida y vuelta nunca genera ganancia (sin arbitraje gratis).
    function testFuzz_RoundTripNoProfit(uint256 dx) public {
        dx = bound(dx, 1e6, 2_000_000e6);
        vm.startPrank(trader);
        uint256 o = pool.exchange(0, 1, dx, 0);
        uint256 back = pool.exchange(1, 0, o, 0);
        vm.stopPrank();
        assertLt(back, dx);
    }

    /// @notice Fuzz: el virtual price nunca baja con swaps.
    function testFuzz_VirtualPriceMonotonic(uint256 dx, uint8 i, uint8 j) public {
        i = uint8(bound(i, 0, 2));
        j = uint8(bound(j, 0, 2));
        vm.assume(i != j);
        dx = bound(dx, 1, 500_000);
        uint256 amt = dx * (i == 2 ? 1e18 : 1e6);
        uint256 vp0 = pool.getVirtualPrice();
        vm.prank(trader);
        pool.exchange(i, j, amt, 0);
        assertGe(pool.getVirtualPrice(), vp0);
    }
}
