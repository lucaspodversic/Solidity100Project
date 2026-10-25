// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CPAMMFactory} from "../src/amm/CPAMMFactory.sol";
import {CPAMMPair} from "../src/amm/CPAMMPair.sol";
import {SlidingWindowOracle} from "../src/SlidingWindowOracle.sol";
import {SimpleTWAPOracle} from "../src/SimpleTWAPOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests de los oráculos TWAP construidos sobre el AMM propio
contract TWAPOracleTest is Test {
    CPAMMFactory factory;
    CPAMMPair pair;
    MockERC20 a;
    MockERC20 b;
    SlidingWindowOracle sliding;
    address attacker = makeAddr("attacker");

    uint256 constant WINDOW = 1 hours;
    uint8 constant GRAN = 6; // períodos de 10 minutos

    function setUp() public {
        vm.warp(1_700_000_000);
        factory = new CPAMMFactory();
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 18);
        pair = CPAMMPair(factory.createPair(address(a), address(b)));
        // Liquidez 1:1 (precio = 1)
        a.mint(address(pair), 1_000e18);
        b.mint(address(pair), 1_000e18);
        pair.mint(address(this));
        sliding = new SlidingWindowOracle(factory, WINDOW, GRAN);
        a.mint(attacker, 1_000_000e18);
        b.mint(attacker, 1_000_000e18);
    }

    /// @dev Swap directo contra el par: manda `amountIn` de `tokenIn` y saca el máximo posible.
    function _swap(address who, MockERC20 tokenIn, uint256 amountIn) internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool zeroForOne = address(tokenIn) == pair.token0();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inWithFee = amountIn * 997;
        uint256 out = (inWithFee * rOut) / (rIn * 1000 + inWithFee);
        vm.prank(who);
        tokenIn.transfer(address(pair), amountIn);
        if (zeroForOne) pair.swap(0, out, who, "");
        else pair.swap(out, 0, who, "");
    }

    /// @dev Llena la ventana con observaciones cada período.
    function _fillWindow() internal {
        for (uint256 i; i <= GRAN; i++) {
            sliding.update(address(a), address(b));
            vm.warp(block.timestamp + WINDOW / GRAN);
        }
        sliding.update(address(a), address(b));
    }

    function test_SlidingWindowReturnsStablePrice() public {
        _fillWindow();
        uint256 out = sliding.consult(address(a), 1e18, address(b));
        assertApproxEqRel(out, 1e18, 1e12);
    }

    function test_ConsultRevertsWithoutHistory() public {
        sliding.update(address(a), address(b));
        vm.expectRevert(SlidingWindowOracle.MissingHistoricalObservation.selector);
        sliding.consult(address(a), 1e18, address(b));
    }

    function test_ConsultRevertsIfKeeperStopped() public {
        _fillWindow();
        vm.warp(block.timestamp + 2 * WINDOW); // nadie actualizó
        vm.expectRevert(SlidingWindowOracle.MissingHistoricalObservation.selector);
        sliding.consult(address(a), 1e18, address(b));
    }

    /// @notice Ataque clásico: mover el spot en un bloque (p. ej. con flash loan) y leer.
    function test_SameBlockManipulationDoesNotMoveTWAP() public {
        _fillWindow();
        uint256 before = sliding.consult(address(a), 1e18, address(b));
        _swap(attacker, b, 1_000e18); // dobla las reservas de B: el precio de A ~ x4
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 spotA = address(a) == pair.token0() ? (uint256(r1) * 1e18) / r0 : (uint256(r0) * 1e18) / r1;
        assertGt(spotA, 3.9e18, "el spot si se movio");
        uint256 afterSwap = sliding.consult(address(a), 1e18, address(b));
        assertEq(afterSwap, before, "el TWAP no se mueve en el mismo bloque");
    }

    /// @notice Sostener el precio manipulado un período (1/6 de la ventana) mueve el TWAP
    ///         sólo proporcionalmente, y el atacante queda expuesto al arbitraje todo ese tiempo.
    function test_SustainedManipulationMovesProportionally() public {
        _fillWindow();
        _swap(attacker, b, 1_000e18); // spot ~4
        vm.warp(block.timestamp + WINDOW / GRAN);
        sliding.update(address(a), address(b));
        uint256 twap = sliding.consult(address(a), 1e18, address(b));
        // ~ (5·1 + 1·4)/6 = 1,5 aprox.
        assertGt(twap, 1.3e18);
        assertLt(twap, 1.7e18);
    }

    function test_SimpleOracle() public {
        SimpleTWAPOracle simple = new SimpleTWAPOracle(address(pair), 1 hours, 2 hours);
        vm.expectRevert(SimpleTWAPOracle.PeriodNotElapsed.selector);
        simple.update();
        // Nota: con via_ir, `block.timestamp` puede re-leerse después de vm.warp, por eso
        // fijamos t0 con vm.getBlockTimestamp().
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 30 minutes);
        _swap(attacker, a, 1_000e18); // precio de A cae a ~1/4 durante la segunda media hora
        vm.warp(t0 + 60 minutes);
        simple.update();
        uint256 out = simple.consult(address(a), 1e18);
        // Promedio ~ (1 + 0,25)/2 = 0,625
        assertApproxEqRel(out, 0.625e18, 0.02e18);
        // El inverso: B vale ~ (1 + 4)/2 = 2,5 (ojo: TWAP aritmético no es simétrico)
        assertApproxEqRel(simple.consult(address(b), 1e18), 2.5e18, 0.02e18);
    }

    function test_SimpleOracleStale() public {
        SimpleTWAPOracle simple = new SimpleTWAPOracle(address(pair), 1 hours, 2 hours);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 1 hours);
        simple.update();
        vm.warp(t0 + 4 hours);
        vm.expectRevert(SimpleTWAPOracle.StalePrice.selector);
        simple.consult(address(a), 1e18);
    }

    function test_InvalidToken() public {
        SimpleTWAPOracle simple = new SimpleTWAPOracle(address(pair), 1 hours, 2 hours);
        vm.warp(block.timestamp + 1 hours);
        simple.update();
        vm.expectRevert(SimpleTWAPOracle.InvalidToken.selector);
        simple.consult(address(0xBEEF), 1e18);
    }

    /// @notice Fuzz: un swap en el mismo bloque, de cualquier tamaño, nunca mueve el TWAP.
    function testFuzz_SameBlockSwapIgnored(uint256 amt) public {
        amt = bound(amt, 1e15, 500_000e18);
        _fillWindow();
        uint256 before = sliding.consult(address(a), 1e18, address(b));
        _swap(attacker, a, amt);
        assertEq(sliding.consult(address(a), 1e18, address(b)), before);
    }
}
