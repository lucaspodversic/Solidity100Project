// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {FlashLoanExecutor} from "../src/FlashLoanExecutor.sol";
import {SwapAdapter} from "../src/adapters/SwapAdapter.sol";
import {AssertBalanceAdapter} from "../src/adapters/AssertBalanceAdapter.sol";
import {CallAdapter} from "../src/adapters/CallAdapter.sol";
import {FlashLender} from "../src/mocks/FlashLender.sol";
import {SimpleAMM} from "../src/mocks/SimpleAMM.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {EvilAdapter} from "../src/mocks/EvilAdapter.sol";

/// @title Tests del executor modular de flash loans
/// @notice Escenario: dos AMMs WETH/USDC desbalanceados (ETH a 2000 en A y a 2200 en B).
///         La receta compra barato en A y vende caro en B con capital prestado.
contract FlashLoanExecutorTest is Test {
    MockERC20 usdc;
    MockERC20 weth;
    SimpleAMM ammA; // ETH a 2000
    SimpleAMM ammB; // ETH a 2200
    FlashLender lender;
    FlashLoanExecutor ex;
    SwapAdapter swapA;
    AssertBalanceAdapter guardA;
    CallAdapter callA;
    address owner = makeAddr("owner");
    address attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        ammA = new SimpleAMM(IERC20(address(weth)), IERC20(address(usdc)));
        ammB = new SimpleAMM(IERC20(address(weth)), IERC20(address(usdc)));
        weth.mint(address(this), 200e18);
        usdc.mint(address(this), 420_000e6);
        weth.approve(address(ammA), type(uint256).max);
        usdc.approve(address(ammA), type(uint256).max);
        weth.approve(address(ammB), type(uint256).max);
        usdc.approve(address(ammB), type(uint256).max);
        ammA.seed(100e18, 200_000e6);
        ammB.seed(100e18, 220_000e6);

        lender = new FlashLender(9); // 9 bps de fee
        usdc.mint(address(lender), 1_000_000e6);

        vm.startPrank(owner);
        ex = new FlashLoanExecutor();
        swapA = new SwapAdapter();
        guardA = new AssertBalanceAdapter();
        callA = new CallAdapter();
        ex.setAdapter(address(swapA), true);
        ex.setAdapter(address(guardA), true);
        ex.setAdapter(address(callA), true);
        ex.setLender(address(lender), true);
        vm.stopPrank();
    }

    /// @dev Receta de arbitraje: USDC → WETH en A, guarda de saldo, WETH → USDC en B (USE_PREV).
    ///      OJO: hace llamadas view (USE_PREV), así que hay que armarla ANTES de `vm.prank`.
    function _arb(uint256 amount) internal view returns (FlashLoanExecutor.Step[] memory s) {
        s = new FlashLoanExecutor.Step[](3);
        s[0] = FlashLoanExecutor.Step(address(swapA), abi.encode(address(ammA), address(usdc), amount, uint256(0)));
        s[1] = FlashLoanExecutor.Step(address(guardA), abi.encode(address(weth), uint256(1)));
        s[2] = FlashLoanExecutor.Step(
            address(swapA), abi.encode(address(ammB), address(weth), swapA.USE_PREV(), uint256(0))
        );
    }

    /// @notice Camino feliz: el arbitraje deja ganancia neta, el lender cobra y no queda polvo.
    function test_FlashArbitrageProfit() public {
        FlashLoanExecutor.Step[] memory s = _arb(5_000e6);
        vm.prank(owner);
        uint256 profit = ex.run(lender, address(usdc), 5_000e6, s, 100e6);
        assertGt(profit, 190e6);
        assertEq(usdc.balanceOf(owner), profit);
        assertEq(usdc.balanceOf(address(ex)), 0);
        assertEq(weth.balanceOf(address(ex)), 0, "todo el WETH se vendio");
        assertEq(usdc.balanceOf(address(lender)), 1_000_000e6 + 4.5e6, "lender cobro fee");
    }

    /// @notice Si la ganancia no llega a `minProfit`, toda la transacción revierte.
    function test_InsufficientProfitReverts() public {
        FlashLoanExecutor.Step[] memory s = _arb(5_000e6);
        vm.prank(owner);
        vm.expectRevert();
        ex.run(lender, address(usdc), 5_000e6, s, 1_000e6);
    }

    /// @notice Receta perdedora: no alcanza para repagar el flash loan, así que revierte.
    function test_ReverseArbLosesAndReverts() public {
        FlashLoanExecutor.Step[] memory s = new FlashLoanExecutor.Step[](2);
        s[0] = FlashLoanExecutor.Step(address(swapA), abi.encode(address(ammB), address(usdc), uint256(5_000e6), uint256(0)));
        s[1] = FlashLoanExecutor.Step(address(swapA), abi.encode(address(ammA), address(weth), swapA.USE_PREV(), uint256(0)));
        vm.prank(owner);
        vm.expectRevert();
        ex.run(lender, address(usdc), 5_000e6, s, 0);
    }

    /// @notice El error de un paso se propaga con su índice y el motivo original.
    function test_StepFailureBubbles() public {
        FlashLoanExecutor.Step[] memory s = new FlashLoanExecutor.Step[](1);
        s[0] = FlashLoanExecutor.Step(address(guardA), abi.encode(address(weth), uint256(1e18)));
        bytes memory inner = abi.encodeWithSelector(
            AssertBalanceAdapter.BalanceTooLow.selector, address(weth), uint256(0), uint256(1e18)
        );
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FlashLoanExecutor.StepFailed.selector, 0, inner));
        ex.run(lender, address(usdc), 1e6, s, 0);
    }

    /// @notice Un adapter no aprobado no puede ejecutarse.
    function test_AdapterNotWhitelisted() public {
        SwapAdapter rogue = new SwapAdapter();
        FlashLoanExecutor.Step[] memory s = new FlashLoanExecutor.Step[](1);
        s[0] = FlashLoanExecutor.Step(address(rogue), "");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FlashLoanExecutor.AdapterNotAllowed.selector, address(rogue)));
        ex.run(lender, address(usdc), 1e6, s, 0);
    }

    function test_OnlyOwnerCanRun() public {
        FlashLoanExecutor.Step[] memory s = _arb(5_000e6);
        vm.prank(attacker);
        vm.expectRevert();
        ex.run(lender, address(usdc), 5_000e6, s, 0);
    }

    /// @notice Las tres defensas del callback ERC-3156.
    function test_CallbackGuards() public {
        bytes memory data = abi.encode(_arb(1e6));
        // 1) llamada directa desde una cuenta cualquiera
        vm.prank(attacker);
        vm.expectRevert(FlashLoanExecutor.UntrustedLender.selector);
        ex.onFlashLoan(address(ex), address(usdc), 1e6, 0, data);
        // 2) flash loan iniciado por un tercero con el executor como receptor
        vm.prank(attacker);
        vm.expectRevert(FlashLoanExecutor.UntrustedInitiator.selector);
        lender.flashLoan(IERC3156FlashBorrower(address(ex)), address(usdc), 1e6, data);
        // 3) lender confiable "falsificando" initiator == executor fuera de una ejecución
        vm.prank(address(lender));
        vm.expectRevert(FlashLoanExecutor.NotExecuting.selector);
        ex.onFlashLoan(address(ex), address(usdc), 1e6, 0, data);
    }

    function test_UntrustedLenderRejected() public {
        FlashLender other = new FlashLender(0);
        FlashLoanExecutor.Step[] memory s = _arb(5_000e6);
        vm.prank(owner);
        vm.expectRevert(FlashLoanExecutor.UntrustedLender.selector);
        ex.run(other, address(usdc), 5_000e6, s, 0);
    }

    /// @notice Receta con capital propio + CallAdapter genérico; el approve queda en 0.
    function test_RunWithoutLoanUsingCallAdapter() public {
        usdc.mint(address(ex), 1_000e6);
        CallAdapter.CallParams memory cp = CallAdapter.CallParams({
            target: address(ammA),
            approveToken: address(usdc),
            approveAmount: 1_000e6,
            callData: abi.encodeCall(SimpleAMM.swap, (address(usdc), 1_000e6, 0, address(ex))),
            returnsUint: true
        });
        FlashLoanExecutor.Step[] memory s = new FlashLoanExecutor.Step[](2);
        s[0] = FlashLoanExecutor.Step(address(callA), abi.encode(cp));
        s[1] = FlashLoanExecutor.Step(address(swapA), abi.encode(address(ammB), address(weth), swapA.USE_PREV(), uint256(0)));
        vm.prank(owner);
        ex.runWithoutLoan(address(usdc), 0, s, 0);
        assertGt(usdc.balanceOf(owner), 0);
        assertEq(usdc.allowance(address(ex), address(ammA)), 0, "approve limpiado");
    }

    /// @notice Demostración: un adapter malicioso aprobado roba el ownership vía delegatecall.
    function test_EvilAdapterShowsWhyWhitelistMatters() public {
        EvilAdapter evil = new EvilAdapter(attacker);
        vm.prank(owner);
        ex.setAdapter(address(evil), true); // error humano del owner
        FlashLoanExecutor.Step[] memory s = new FlashLoanExecutor.Step[](1);
        s[0] = FlashLoanExecutor.Step(address(evil), "");
        vm.prank(owner);
        ex.runWithoutLoan(address(usdc), 0, s, 0);
        assertEq(ex.owner(), attacker, "el delegatecall sobrescribio el owner");
    }

    /// @notice Fuzz: para cualquier tamaño el executor termina sin tokens y el owner
    ///         nunca pierde (o hay ganancia o revierte todo).
    function testFuzz_ArbNeverLeavesDust(uint256 amount) public {
        amount = bound(amount, 1e6, 50_000e6);
        FlashLoanExecutor.Step[] memory s = _arb(amount);
        vm.prank(owner);
        try ex.run(lender, address(usdc), amount, s, 0) returns (uint256 p) {
            assertEq(usdc.balanceOf(owner), p);
        } catch {}
        assertEq(usdc.balanceOf(address(ex)), 0);
        assertEq(weth.balanceOf(address(ex)), 0);
    }
}
