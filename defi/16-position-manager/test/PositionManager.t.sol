// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {IVenue} from "../src/venues/IVenue.sol";
import {VenueBase} from "../src/venues/VenueBase.sol";
import {LendingPoolVenue} from "../src/venues/LendingPoolVenue.sol";
import {ERC4626Venue} from "../src/venues/ERC4626Venue.sol";
import {LendingPool} from "../src/protocol/LendingPool.sol";
import {JumpRateModel} from "../src/protocol/JumpRateModel.sol";
import {PriceOracle} from "../src/protocol/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockYieldVault} from "../src/mocks/MockYieldVault.sol";
import {LossyVenue} from "../src/mocks/LossyVenue.sol";

/// @title Tests del gestor de posiciones multi-protocolo
/// @notice Cartera de 100 000 USDC: 40 % LendingPool, 40 % vault A, 10 % vault B, 10 % colchón.
contract PositionManagerTest is Test {
    MockERC20 usdc;
    MockERC20 weth;
    PriceOracle oracle;
    LendingPool pool;
    MockYieldVault vaultA;
    MockYieldVault vaultB;
    PositionManager pm;
    LendingPoolVenue lendV;
    ERC4626Venue aV;
    ERC4626Venue bV;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address borrower = makeAddr("borrower");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        oracle = new PriceOracle();
        oracle.setMaxAge(3650 days); // los tests avanzan el tiempo sin refrescar precios
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        JumpRateModel model = new JumpRateModel(0, 0.04e18, 0.75e18, 0.8e18);
        pool = new LendingPool(oracle, makeAddr("treasury"));
        pool.listMarket(address(weth), 0.75e18, 0.8e18, 0.05e18, 0.1e18, model);
        pool.listMarket(address(usdc), 0.8e18, 0.85e18, 0.05e18, 0.1e18, model);
        vaultA = new MockYieldVault(IERC20(address(usdc)), "VaultA");
        vaultB = new MockYieldVault(IERC20(address(usdc)), "VaultB");

        vm.startPrank(owner);
        pm = new PositionManager(IERC20(address(usdc)), keeper);
        lendV = new LendingPoolVenue(address(pm), IERC20(address(usdc)), pool);
        aV = new ERC4626Venue(address(pm), IERC4626(address(vaultA)));
        bV = new ERC4626Venue(address(pm), IERC4626(address(vaultB)));
        pm.addVenue(lendV);
        pm.addVenue(aV);
        pm.addVenue(bV);
        uint16[] memory t = new uint16[](3);
        t[0] = 4000;
        t[1] = 4000;
        t[2] = 1000;
        pm.setTargets(t);
        usdc.mint(owner, 100_000e6);
        usdc.approve(address(pm), type(uint256).max);
        pm.deposit(100_000e6);
        vm.stopPrank();

        // deudor del pool (genera intereses para el venue de lending)
        weth.mint(borrower, 100e18);
        vm.startPrank(borrower);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), 100e18);
        vm.stopPrank();
    }

    function _rebalance() internal {
        vm.prank(keeper);
        pm.rebalance();
    }

    function test_InitialRebalanceHitsTargets() public {
        assertTrue(pm.needsRebalance());
        _rebalance();
        assertEq(lendV.totalAssets(), 40_000e6);
        assertApproxEqAbs(aV.totalAssets(), 40_000e6, 1);
        assertApproxEqAbs(bV.totalAssets(), 10_000e6, 1);
        assertApproxEqAbs(usdc.balanceOf(address(pm)), 10_000e6, 2, "colchon 10 %");
        assertFalse(pm.needsRebalance());
    }

    function test_CooldownAndNoOp() public {
        _rebalance();
        vm.prank(keeper);
        vm.expectRevert(PositionManager.CooldownActive.selector);
        pm.rebalance();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(keeper);
        vm.expectRevert(PositionManager.NoRebalanceNeeded.selector);
        pm.rebalance();
    }

    /// @notice El vault A rinde 20 % → queda sobreponderado → el rebalanceo reparte la ganancia.
    function test_YieldDriftTriggersRebalance() public {
        _rebalance();
        vaultA.simulateYield(20_000e6); // vault A sólo tiene nuestras shares: +20k para nosotros
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 tvBefore = pm.totalValue();
        assertApproxEqAbs(tvBefore, 120_000e6, 2);
        assertTrue(pm.needsRebalance());
        _rebalance();
        assertFalse(pm.needsRebalance());
        assertApproxEqAbs(lendV.totalAssets(), 48_000e6, 2);
        assertApproxEqAbs(aV.totalAssets(), 48_000e6, 2);
        assertApproxEqAbs(pm.totalValue(), tvBefore, 3, "rebalancear no crea ni destruye valor");
    }

    /// @notice El venue de lending acumula intereses de los deudores.
    function test_LendingVenueEarnsInterest() public {
        _rebalance();
        vm.prank(borrower);
        pool.borrow(address(usdc), 30_000e6); // utilización 75 %
        vm.warp(vm.getBlockTimestamp() + 365 days);
        pool.accrue(address(usdc));
        assertGt(lendV.totalAssets(), 40_000e6 + 900e6, "~3,4 % APR * 0,9 al supply");
    }

    /// @notice Con el pool ilíquido el retiro cae a los otros venues en orden.
    function test_WithdrawFallsThroughIlliquidVenue() public {
        _rebalance();
        vm.prank(borrower);
        pool.borrow(address(usdc), 39_000e6); // quedan 1 000 de cash en el pool
        assertEq(lendV.maxWithdraw(), 1_000e6);
        vm.prank(owner);
        pm.withdraw(50_000e6, owner);
        assertEq(usdc.balanceOf(owner), 50_000e6);
        // 10k colchón + 1k lending + 39k del vault A
        assertApproxEqAbs(aV.totalAssets(), 1_000e6, 2);
    }

    function test_WithdrawMoreThanLiquidReverts() public {
        _rebalance();
        vm.prank(borrower);
        pool.borrow(address(usdc), 40_000e6);
        vm.prank(owner);
        vm.expectRevert();
        pm.withdraw(90_000e6, owner);
    }

    /// @notice Un venue con fee de salida oculto: el control maxLossBps frena el rebalanceo.
    function test_LossyVenueBlocksRebalance() public {
        vm.startPrank(owner);
        LossyVenue lossy = new LossyVenue(address(pm), IERC20(address(usdc)));
        pm.addVenue(lossy);
        uint16[] memory t = new uint16[](4);
        t[3] = 9000;
        pm.setTargets(t);
        vm.stopPrank();
        _rebalance(); // todo al venue con pérdida (depositar no cuesta)
        lossy.setHaircut(100); // 1 % al salir

        vm.startPrank(owner);
        t[3] = 0;
        t[0] = 9000;
        pm.setTargets(t);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(keeper);
        vm.expectRevert(); // LossTooHigh: perdería 900 USDC > 0,1 %
        pm.rebalance();
    }

    /// @notice Hackeo en el vault B: emergencyExit rescata lo que queda y lo saca de la rotación.
    function test_EmergencyExit() public {
        _rebalance();
        vaultB.simulateLoss(4_000e6); // B pierde 40 %
        vm.prank(owner);
        pm.emergencyExit(2);
        assertEq(bV.totalAssets(), 0);
        (, uint16 tB) = pm.venues(2);
        assertEq(tB, 0);
        assertApproxEqAbs(usdc.balanceOf(address(pm)), 16_000e6, 2);
    }

    function test_AccessControl() public {
        vm.expectRevert(PositionManager.NotKeeper.selector);
        pm.rebalance();
        vm.expectRevert(VenueBase.OnlyManager.selector);
        aV.withdraw(1);
        vm.expectRevert();
        pm.withdraw(1, address(this));
    }

    function test_ConfigValidation() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockYieldVault dv = new MockYieldVault(IERC20(address(dai)), "DaiVault");
        vm.startPrank(owner);
        ERC4626Venue wrong = new ERC4626Venue(address(pm), IERC4626(address(dv)));
        vm.expectRevert(PositionManager.WrongAsset.selector);
        pm.addVenue(wrong);
        uint16[] memory t = new uint16[](3);
        t[0] = 6000;
        t[1] = 5000;
        vm.expectRevert(PositionManager.BadTargets.selector);
        pm.setTargets(t);
        vm.stopPrank();
    }

    /// @notice Fuzz: con rendimientos arbitrarios, rebalancear conserva el valor y deja la
    ///         cartera dentro del umbral.
    function testFuzz_RebalanceConservesValue(uint256 ya, uint256 yb) public {
        _rebalance();
        ya = bound(ya, 0, 50_000e6);
        yb = bound(yb, 0, 50_000e6);
        vaultA.simulateYield(ya);
        vaultB.simulateYield(yb);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        uint256 before = pm.totalValue();
        if (!pm.needsRebalance()) return;
        _rebalance();
        assertApproxEqAbs(pm.totalValue(), before, 5);
        assertFalse(pm.needsRebalance());
    }
}
