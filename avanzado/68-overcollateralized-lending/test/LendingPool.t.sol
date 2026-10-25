// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool, IERC3156FlashBorrower, IOracle} from "../src/LendingPool.sol";
import {LiquidationBot} from "../src/LiquidationBot.sol";
import {MockToken, MockOracle, MockDex} from "../src/Mocks.sol";

/// @dev Receptor que intenta depositar los fondos prestados (debe fallar).
contract DepositDuringFlash is IERC3156FlashBorrower {
    LendingPool pool;
    constructor(LendingPool p) { pool = p; }
    function go(uint256 a) external { pool.flashLoan(this, address(pool.asset()), a, ""); }
    function onFlashLoan(address, address t, uint256 a, uint256 f, bytes calldata) external returns (bytes32) {
        MockToken(t).approve(address(pool), type(uint256).max);
        pool.deposit(a); // FlashActive
        MockToken(t).mint(address(this), f);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @dev Receptor que no devuelve los fondos.
contract Thief is IERC3156FlashBorrower {
    function onFlashLoan(address, address, uint256, uint256, bytes calldata) external pure returns (bytes32) {
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @dev Receptor honesto que paga la fee.
contract Honest is IERC3156FlashBorrower {
    function onFlashLoan(address, address t, uint256 a, uint256 f, bytes calldata) external returns (bytes32) {
        MockToken(t).mint(address(this), f);
        MockToken(t).approve(msg.sender, a + f);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

contract LendingPoolTest is Test {
    MockToken dai;
    MockToken weth;
    MockOracle oracle;
    LendingPool pool;
    MockDex dex;
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address reserveTo = makeAddr("reserve");

    function setUp() public {
        vm.warp(1_700_000_000);
        dai = new MockToken("Dai", "DAI");
        weth = new MockToken("WETH", "WETH");
        oracle = new MockOracle(2000e8);
        pool = new LendingPool(dai, weth, IOracle(address(oracle)), reserveTo);
        dex = new MockDex(oracle);
        dai.mint(lender, 1_000_000e18);
        weth.mint(borrower, 100 ether);
        vm.prank(lender);
        dai.approve(address(pool), type(uint256).max);
        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        pool.deposit(100_000e18);
    }

    function _borrow(uint256 coll, uint256 amt) internal {
        vm.startPrank(borrower);
        pool.addCollateral(coll);
        pool.borrow(amt);
        vm.stopPrank();
    }

    function test_BorrowUpToLTV() public {
        _borrow(10 ether, 15_000e18); // 20k * 75%
        assertEq(dai.balanceOf(borrower), 15_000e18);
        vm.prank(borrower);
        vm.expectRevert(LendingPool.Unhealthy.selector);
        pool.borrow(1);
    }

    function test_RevertWhen_RemoveCollateralUnhealthy() public {
        _borrow(10 ether, 10_000e18);
        vm.prank(borrower);
        vm.expectRevert(LendingPool.Unhealthy.selector);
        pool.removeCollateral(4 ether);
        vm.prank(borrower);
        pool.removeCollateral(3 ether);
    }

    function test_InterestRateCurve() public {
        assertEq(pool.borrowRate(), 0.02e18); // U = 0
        _borrow(100 ether, 80_000e18); // U = 80% (kink)
        assertApproxEqAbs(pool.borrowRate(), 0.12e18, 1e6);
        uint256 tenth = pool.shares(lender) / 10; // cacheado: vm.prank se consumiría con el getter
        vm.prank(lender);
        pool.withdraw(tenth); // sube U por encima del kink
        assertGt(pool.borrowRate(), 0.12e18);
    }

    function test_InterestAccruesToLenders() public {
        _borrow(100 ether, 50_000e18);
        uint256 before = pool.balanceOfUnderlying(lender);
        vm.warp(block.timestamp + 365 days);
        pool.accrue();
        // U = 50% -> 2% + 10%*0.5/0.8 = 8,25%; 90% para prestamistas
        uint256 interest = 50_000e18 * 825 / 10_000;
        assertApproxEqRel(pool.balanceOfUnderlying(lender) - before, interest * 9 / 10, 1e15);
        assertApproxEqRel(pool.debtOf(borrower), 50_000e18 + interest, 1e15);
        pool.withdrawReserves();
        assertApproxEqRel(dai.balanceOf(reserveTo), interest / 10, 1e15);
    }

    function test_RepayFull() public {
        _borrow(10 ether, 10_000e18);
        vm.warp(block.timestamp + 30 days);
        dai.mint(borrower, 1_000e18);
        vm.prank(borrower);
        pool.repay(borrower, type(uint256).max);
        assertEq(pool.debtOf(borrower), 0);
        vm.prank(borrower);
        pool.removeCollateral(10 ether);
    }

    function test_Liquidation() public {
        _borrow(10 ether, 15_000e18);
        oracle.set(1800e8); // HF = 18000*0.8/15000 = 0.96
        assertLt(pool.healthFactor(borrower), 1e18);
        address liq = makeAddr("liq");
        dai.mint(liq, 7_500e18);
        vm.startPrank(liq);
        dai.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.TooMuchRepay.selector);
        pool.liquidate(borrower, 7_600e18);
        uint256 seized = pool.liquidate(borrower, 7_500e18);
        vm.stopPrank();
        // 7500/1800 * 1.05 = 4.375 ETH
        // redondeo hacia abajo (a favor del pool): puede faltar 1 wei
        assertApproxEqAbs(seized, 4.375 ether, 1);
        assertEq(weth.balanceOf(liq), seized);
        assertGt(pool.healthFactor(borrower), 1e18);
    }

    function test_RevertWhen_LiquidateHealthy() public {
        _borrow(10 ether, 10_000e18);
        vm.expectRevert(LendingPool.Healthy.selector);
        pool.liquidate(borrower, 1);
    }

    function test_LiquidationBotWithFlashLoan() public {
        _borrow(10 ether, 15_000e18);
        oracle.set(1800e8);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        LiquidationBot bot = new LiquidationBot(pool, dex);
        uint256 cashBefore = pool.cash();
        vm.prank(keeper);
        bot.run(borrower, 7_500e18);
        // ganancia = 5% bonus (375) − fee 0,09% (6.75)
        assertApproxEqAbs(dai.balanceOf(keeper), 375e18 - 6.75e18, 1e15);
        // el pool recuperó la deuda repagada + fee
        assertEq(pool.cash(), cashBefore + 7_500e18 + 6.75e18);
    }

    function test_FlashLoanFeeToLenders() public {
        Honest h = new Honest();
        uint256 before = pool.totalAssets();
        pool.flashLoan(h, address(dai), 50_000e18, "");
        assertEq(pool.totalAssets(), before + 45e18);
    }

    function test_RevertWhen_FlashLoanNotRepaid() public {
        Thief t = new Thief();
        vm.expectRevert(); // ERC20InsufficientAllowance
        pool.flashLoan(t, address(dai), 1_000e18, "");
    }

    function test_RevertWhen_DepositDuringFlash() public {
        DepositDuringFlash d = new DepositDuringFlash(pool);
        vm.expectRevert(LendingPool.FlashActive.selector);
        d.go(1_000e18);
    }

    function test_RevertWhen_FlashTooBig() public {
        Honest h = new Honest();
        vm.expectRevert(LendingPool.InsufficientCash.selector);
        pool.flashLoan(h, address(dai), 200_000e18, "");
    }

    /// Donar tokens directo no cambia el precio de las shares (cash interno).
    function test_DonationDoesNotInflate() public {
        uint256 before = pool.balanceOfUnderlying(lender);
        dai.mint(address(pool), 1_000_000e18);
        assertEq(pool.balanceOfUnderlying(lender), before);
    }

    /// Primer depositante con 1 wei no puede robar al segundo (shares virtuales).
    function test_InflationAttackMitigated() public {
        LendingPool p2 = new LendingPool(dai, weth, IOracle(address(oracle)), reserveTo);
        address attacker = makeAddr("attacker");
        dai.mint(attacker, 10_001e18);
        vm.startPrank(attacker);
        dai.approve(address(p2), type(uint256).max);
        p2.deposit(1);
        dai.transfer(address(p2), 10_000e18); // donación: ignorada
        vm.stopPrank();
        vm.prank(lender);
        dai.approve(address(p2), type(uint256).max);
        vm.prank(lender);
        p2.deposit(1_000e18);
        assertApproxEqRel(p2.balanceOfUnderlying(lender), 1_000e18, 1e15);
    }

    /// Fuzz: los prestamistas nunca retiran más de lo que hay; solvencia del pool.
    function testFuzz_Solvency(uint256 amt, uint32 dt) public {
        amt = bound(amt, 1e18, 15_000e18);
        dt = uint32(bound(dt, 1, 2 * 365 days));
        _borrow(10 ether, amt);
        vm.warp(block.timestamp + dt);
        pool.accrue();
        dai.mint(borrower, pool.debtOf(borrower));
        vm.prank(borrower);
        pool.repay(borrower, type(uint256).max);
        pool.withdrawReserves();
        uint256 s = pool.shares(lender);
        vm.prank(lender);
        pool.withdraw(s);
        assertGe(dai.balanceOf(address(pool)), pool.cash());
    }
}
