// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CPAMMFactory} from "../src/CPAMMFactory.sol";
import {CPAMMPair, ICPAMMCallee} from "../src/CPAMMPair.sol";
import {CPAMMRouter} from "../src/CPAMMRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev Contrato que intenta un flash swap sin devolver los fondos (debe revertir por k).
contract BadBorrower is ICPAMMCallee {
    function cpammCall(address, uint256, uint256, bytes calldata) external {}
}

/// @dev Flash borrower honesto: devuelve lo prestado + comisión.
contract GoodBorrower is ICPAMMCallee {
    MockERC20 public t;
    constructor(MockERC20 _t) { t = _t; }
    function cpammCall(address, uint256 a0, uint256 a1, bytes calldata) external {
        uint256 amt = a0 + a1;
        // comisión ~0,3% redondeada hacia arriba (fórmula de Uniswap: amt*1000/997 + 1)
        uint256 repay = (amt * 1000) / 997 + 1;
        t.mint(address(this), repay - amt); // simula ganancia de arbitraje
        t.transfer(msg.sender, repay);
    }
}

/// @title Tests del AMM de producto constante
contract CPAMMTest is Test {
    CPAMMFactory factory;
    CPAMMRouter router;
    MockERC20 a;
    MockERC20 b;
    MockERC20 c;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        factory = new CPAMMFactory();
        router = new CPAMMRouter(factory);
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 18);
        c = new MockERC20("C", "C", 18);
        address[2] memory us = [alice, bob];
        for (uint256 i; i < 2; i++) {
            a.mint(us[i], 1_000_000 ether);
            b.mint(us[i], 1_000_000 ether);
            c.mint(us[i], 1_000_000 ether);
            vm.startPrank(us[i]);
            a.approve(address(router), type(uint256).max);
            b.approve(address(router), type(uint256).max);
            c.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _add(address who, MockERC20 x, MockERC20 y, uint256 ax, uint256 ay) internal returns (uint256 liq) {
        vm.prank(who);
        (,, liq) = router.addLiquidity(address(x), address(y), ax, ay, 0, 0, who, block.timestamp);
    }

    function test_FirstDepositBurnsMinimumLiquidity() public {
        uint256 liq = _add(alice, a, b, 100 ether, 400 ether);
        // sqrt(100e18*400e18) = 200e18
        assertEq(liq, 200 ether - 1000);
        CPAMMPair p = CPAMMPair(factory.getPair(address(a), address(b)));
        assertEq(p.balanceOf(address(0xdead)), 1000);
    }

    function test_SwapExactIn_MatchesFormula() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        uint256 expected = router.getAmountOut(10 ether, 1000 ether, 1000 ether);
        uint256 before = b.balanceOf(bob);
        vm.prank(bob);
        router.swapExactTokensForTokens(10 ether, expected, path, bob, block.timestamp);
        assertEq(b.balanceOf(bob) - before, expected);
        // sin comisión serían 9.90099; con 0,3% debe ser menos
        assertLt(expected, 9.901 ether);
    }

    function test_KNeverDecreases() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        CPAMMPair p = CPAMMPair(factory.getPair(address(a), address(b)));
        (uint112 r0, uint112 r1,) = p.getReserves();
        uint256 k0 = uint256(r0) * r1;
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        vm.prank(bob);
        router.swapExactTokensForTokens(50 ether, 0, path, bob, block.timestamp);
        (r0, r1,) = p.getReserves();
        assertGt(uint256(r0) * r1, k0, "las comisiones deben hacer crecer k");
    }

    function test_SlippageProtectionReverts() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        vm.prank(bob);
        vm.expectRevert(CPAMMRouter.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(10 ether, 10 ether, path, bob, block.timestamp);
    }

    function test_DeadlineReverts() public {
        vm.warp(1000);
        vm.prank(alice);
        vm.expectRevert(CPAMMRouter.Expired.selector);
        router.addLiquidity(address(a), address(b), 1 ether, 1 ether, 0, 0, alice, 999);
    }

    function test_RemoveLiquidityReturnsFeesToLP() public {
        uint256 liq = _add(alice, a, b, 1000 ether, 1000 ether);
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        address[] memory back = new address[](2);
        back[0] = address(b);
        back[1] = address(a);
        // Bob hace ida y vuelta varias veces generando comisiones
        for (uint256 i; i < 5; i++) {
            vm.startPrank(bob);
            uint256[] memory out = router.swapExactTokensForTokens(100 ether, 0, path, bob, block.timestamp);
            router.swapExactTokensForTokens(out[1], 0, back, bob, block.timestamp);
            vm.stopPrank();
        }
        address pair = factory.getPair(address(a), address(b));
        vm.startPrank(alice);
        CPAMMPair(pair).approve(address(router), liq);
        (uint256 ra, uint256 rb) = router.removeLiquidity(address(a), address(b), liq, 0, 0, alice, block.timestamp);
        vm.stopPrank();
        // Alice recupera más valor total que el depositado (2000) gracias a las comisiones.
        assertGt(ra + rb, 2000 ether - 1 ether);
        assertGt(ra, 1000 ether - 1e6); // el pool terminó con más A
    }

    function test_MultiHopSwap() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        _add(alice, b, c, 1000 ether, 2000 ether);
        address[] memory path = new address[](3);
        path[0] = address(a);
        path[1] = address(b);
        path[2] = address(c);
        uint256[] memory amts = router.getAmountsOut(10 ether, path);
        vm.prank(bob);
        router.swapExactTokensForTokens(10 ether, amts[2], path, bob, block.timestamp);
        assertEq(c.balanceOf(bob), 1_000_000 ether + amts[2]);
    }

    function test_SwapTokensForExactTokens() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        uint256 beforeB = b.balanceOf(bob);
        vm.prank(bob);
        router.swapTokensForExactTokens(5 ether, 10 ether, path, bob, block.timestamp);
        assertEq(b.balanceOf(bob) - beforeB, 5 ether);
    }

    function test_FlashSwapWithoutRepayReverts() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        CPAMMPair p = CPAMMPair(factory.getPair(address(a), address(b)));
        BadBorrower bad = new BadBorrower();
        vm.expectRevert(CPAMMPair.InsufficientInputAmount.selector);
        p.swap(10 ether, 0, address(bad), hex"01");
    }

    function test_FlashSwapWithRepaySucceeds() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        CPAMMPair p = CPAMMPair(factory.getPair(address(a), address(b)));
        MockERC20 t0 = MockERC20(p.token0());
        GoodBorrower good = new GoodBorrower(t0);
        p.swap(10 ether, 0, address(good), hex"01");
        (uint112 r0,,) = p.getReserves();
        assertGt(r0, 1000 ether);
    }

    function test_DirectSwapStealingReverts() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        CPAMMPair p = CPAMMPair(factory.getPair(address(a), address(b)));
        // mandar 1 wei y pedir 10 ether => debe violar k
        a.mint(address(p), 1);
        bool aIs0 = p.token0() == address(a);
        // OJO: calcular antes de expectRevert (que aplica a la siguiente llamada externa).
        vm.expectRevert(CPAMMPair.KInvariant.selector);
        p.swap(aIs0 ? 0 : 10 ether, aIs0 ? 10 ether : 0, bob, "");
    }

    function test_TwapAccumulatorAdvances() public {
        _add(alice, a, b, 1000 ether, 1000 ether);
        CPAMMPair p = CPAMMPair(factory.getPair(address(a), address(b)));
        uint256 c0 = p.price0CumulativeLast();
        vm.warp(block.timestamp + 100);
        p.sync();
        // precio 1:1 => acumulador += 2^112 * 100
        assertEq(p.price0CumulativeLast() - c0, (uint256(1) << 112) * 100);
    }

    function test_CreatePairTwiceReverts() public {
        factory.createPair(address(a), address(b));
        vm.expectRevert(CPAMMFactory.PairExists.selector);
        factory.createPair(address(b), address(a));
    }

    /// @notice Fuzz: cualquier swap respeta k y nunca entrega más que getAmountOut.
    function testFuzz_SwapPreservesK(uint96 amtIn) public {
        vm.assume(amtIn > 1000 && amtIn < 500_000 ether);
        _add(alice, a, b, 1000 ether, 1000 ether);
        CPAMMPair p = CPAMMPair(factory.getPair(address(a), address(b)));
        (uint112 r0, uint112 r1,) = p.getReserves();
        uint256 k0 = uint256(r0) * r1;
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        vm.prank(bob);
        router.swapExactTokensForTokens(amtIn, 0, path, bob, block.timestamp);
        (r0, r1,) = p.getReserves();
        assertGe(uint256(r0) * r1, k0);
    }
}
