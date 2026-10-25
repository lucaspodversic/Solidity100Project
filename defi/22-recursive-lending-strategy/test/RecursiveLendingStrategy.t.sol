// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {RecursiveLendingStrategy} from "../src/RecursiveLendingStrategy.sol";
import {LendingPool} from "../src/protocol/LendingPool.sol";
import {PriceOracle} from "../src/protocol/PriceOracle.sol";
import {JumpRateModel} from "../src/protocol/JumpRateModel.sol";
import {OracleDex} from "../src/mocks/OracleDex.sol";
import {FlashLender} from "../src/mocks/FlashLender.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests de la estrategia de préstamos recursivos (LST / WETH)
/// @notice Escenario: WETH = LST = 2 000 USD. LST: LTV 90 %, umbral 93 %. Liquidez WETH 10 000.
///         El owner aporta 100 LST (200 000 USD de capital).
contract RecursiveLendingStrategyTest is Test {
    MockERC20 weth;
    MockERC20 lst;
    PriceOracle oracle;
    LendingPool pool;
    OracleDex dex;
    FlashLender lender;
    RecursiveLendingStrategy strat;
    address lp = makeAddr("lp");
    address liquidator = makeAddr("liquidator");
    address attacker = makeAddr("attacker");

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        lst = new MockERC20("Liquid Staked ETH", "LST", 18);
        oracle = new PriceOracle();
        oracle.setMaxAge(3650 days);
        oracle.setPrice(address(weth), 2_000e18);
        oracle.setPrice(address(lst), 2_000e18);
        pool = new LendingPool(oracle, makeAddr("treasury"));
        JumpRateModel m = new JumpRateModel(0.005e18, 0.03e18, 1e18, 0.8e18);
        pool.listMarket(address(lst), 0.9e18, 0.93e18, 0.05e18, 0.1e18, m);
        pool.listMarket(address(weth), 0.8e18, 0.85e18, 0.05e18, 0.1e18, m);
        // liquidez de WETH en el pool
        weth.mint(lp, 10_000e18);
        vm.startPrank(lp);
        weth.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), 10_000e18);
        vm.stopPrank();
        // DEX y flash lender con inventario
        dex = new OracleDex(oracle);
        weth.mint(address(dex), 10_000e18);
        lst.mint(address(dex), 10_000e18);
        lender = new FlashLender(5); // 0,05 %
        weth.mint(address(lender), 10_000e18);
        strat = new RecursiveLendingStrategy(
            pool, dex, IERC3156FlashLender(address(lender)), IERC20(address(lst)), IERC20(address(weth))
        );
        lst.mint(address(this), 100e18);
        lst.approve(address(strat), type(uint256).max);
        strat.deposit(100e18);
    }

    function test_InitialPosition() public view {
        (uint256 c, uint256 d, uint256 e) = strat.position();
        assertEq(c, 200_000e18);
        assertEq(d, 0);
        assertEq(e, 200_000e18);
        assertEq(strat.leverage(), 1e18);
    }

    function test_LoopReachesTarget() public {
        uint256 iters = strat.leverageLoop(4e18, 20);
        assertGt(iters, 3, "hacen falta varias vueltas");
        assertApproxEqRel(strat.leverage(), 4e18, 0.02e18);
        assertGe(strat.healthFactor(), strat.minHealthFactor());
    }

    function test_LoopStopsAtMaxIterations() public {
        strat.leverageLoop(6e18, 2);
        assertLt(strat.leverage(), 3e18, "con 2 vueltas no llega");
    }

    function test_FlashReachesTargetInOneShot() public {
        strat.leverageFlash(4e18);
        assertApproxEqRel(strat.leverage(), 4e18, 0.02e18);
        assertEq(weth.balanceOf(address(strat)), 0, "nada suelto");
    }

    function test_FlashIsCheaperThanLoop() public {
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        strat.leverageLoop(5e18, 30);
        uint256 loopGas = g0 - gasleft();
        vm.revertToState(snap);
        g0 = gasleft();
        strat.leverageFlash(5e18);
        uint256 flashGas = g0 - gasleft();
        emit log_named_uint("gas loop ", loopGas);
        emit log_named_uint("gas flash", flashGas);
        assertLt(flashGas, loopGas);
    }

    function test_LeverageLimits() public {
        vm.expectRevert(RecursiveLendingStrategy.BadLeverage.selector);
        strat.leverageFlash(9e18);
        vm.expectRevert(RecursiveLendingStrategy.BadLeverage.selector);
        strat.leverageLoop(1e18, 5);
        // HF a 5x = 0,93 / 0,8 ≈ 1,16 < 1,2 exigido
        strat.setRisk(1.2e18, 100);
        vm.expectPartialRevert(RecursiveLendingStrategy.HealthTooLow.selector);
        strat.leverageFlash(5e18);
    }

    /// @notice 4x durante un año con LST rindiendo 4 % y WETH costando < 1 %: el capital rinde > 12 %.
    function test_LeverageAmplifiesYield() public {
        strat.leverageFlash(4e18);
        (,, uint256 e0) = strat.position();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        oracle.setPrice(address(lst), 2_080e18); // +4 % de staking (tipo de cambio LST/ETH)
        pool.accrue(address(weth));
        (,, uint256 e1) = strat.position();
        uint256 gainBps = ((e1 - e0) * 10_000) / e0;
        emit log_named_uint("rendimiento del capital (bps)", gainBps);
        assertGt(gainBps, 1_200, "aprox. 4*4% - 3*tasa");
    }

    function test_LiquidationRatioAndDepeg() public {
        strat.leverageFlash(4e18);
        uint256 ratio = strat.liquidationRatio();
        assertApproxEqRel(ratio, 0.806e18, 0.01e18, "D/(C*lt) = 0,75/0,93");
        oracle.setPrice(address(lst), 1_700e18); // depeg 15 %: todavía sano
        assertGt(strat.healthFactor(), 1e18);
        oracle.setPrice(address(lst), 1_580e18); // depeg 21 %: liquidable
        assertLt(strat.healthFactor(), 1e18);
        weth.mint(liquidator, 1_000e18);
        vm.startPrank(liquidator);
        weth.approve(address(pool), type(uint256).max);
        pool.liquidate(address(weth), address(lst), address(strat), 100e18);
        vm.stopPrank();
        assertGt(lst.balanceOf(liquidator), 0, "el liquidador cobra colateral con bonus");
    }

    function test_DeleverageStep() public {
        strat.leverageFlash(4e18);
        uint256 l0 = strat.leverage();
        strat.deleverageStep(20e18);
        assertLt(strat.leverage(), l0);
        assertGe(strat.healthFactor(), strat.minHealthFactor());
    }

    function test_UnwindReturnsEquity() public {
        strat.leverageFlash(4e18);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        strat.unwind();
        assertEq(pool.borrowBalance(address(weth), address(strat)), 0);
        assertEq(pool.supplyBalance(address(lst), address(strat)), 0);
        uint256 valueUsd = lst.balanceOf(address(this)) * 2_000 + weth.balanceOf(address(this)) * 2_000;
        assertGt(valueUsd, 194_000e18, "pierde solo fees de swap/flash e interes (~3 %)");
    }

    function test_UnwindWithoutDebt() public {
        strat.unwind();
        assertEq(lst.balanceOf(address(this)), 100e18);
    }

    function test_FlashCallbackAuth() public {
        vm.prank(attacker);
        vm.expectRevert(RecursiveLendingStrategy.UntrustedLender.selector);
        strat.onFlashLoan(attacker, address(weth), 1e18, 0, abi.encode(uint8(1)));
        // un atacante inicia un flash loan apuntando a la estrategia: no hay operación en curso
        vm.prank(attacker);
        vm.expectRevert(RecursiveLendingStrategy.UntrustedLender.selector);
        lender.flashLoan(strat, address(weth), 1e18, abi.encode(uint8(1)));
    }

    function test_OnlyOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert();
        strat.leverageFlash(2e18);
        vm.expectRevert();
        strat.unwind();
        vm.expectRevert();
        strat.sweep(IERC20(address(lst)));
        vm.stopPrank();
    }

    /// @notice Fuzz: cualquier objetivo 1,2x–7x queda cerca del objetivo y con HF sano.
    function testFuzz_FlashLeverage(uint256 target) public {
        target = bound(target, 1.2e18, 7e18);
        strat.leverageFlash(target);
        assertApproxEqRel(strat.leverage(), target, 0.04e18);
        assertGe(strat.healthFactor(), 1.05e18);
    }
}
