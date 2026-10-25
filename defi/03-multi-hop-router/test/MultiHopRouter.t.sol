// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SimplePool} from "../src/SimplePool.sol";
import {MultiHopRouter} from "../src/MultiHopRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests del router multi-salto
/// @dev Grafo de prueba:
///        A —(directo, poca liquidez, 1%)— D
///        A —(profundo, 0,3%)— B —(profundo, 0,3%)— D
///        A —(medio, 0,3%)— C —(medio, 0,3%)— D
contract MultiHopRouterTest is Test {
    MultiHopRouter router;
    MockERC20 A;
    MockERC20 B;
    MockERC20 C;
    MockERC20 D;
    MockERC20 Z; // token aislado (sin pools)
    SimplePool pAD;
    SimplePool pAB;
    SimplePool pBD;
    SimplePool pAC;
    SimplePool pCD;
    address user = makeAddr("user");

    function _pool(MockERC20 x, MockERC20 y, uint256 rx, uint256 ry, uint256 fee) internal returns (SimplePool p) {
        p = new SimplePool(IERC20(address(x)), IERC20(address(y)), fee);
        x.mint(address(this), rx);
        y.mint(address(this), ry);
        x.approve(address(p), rx);
        y.approve(address(p), ry);
        p.addLiquidity(rx, ry);
        router.addPool(p);
    }

    function setUp() public {
        router = new MultiHopRouter();
        A = new MockERC20("A", "A", 18);
        B = new MockERC20("B", "B", 18);
        C = new MockERC20("C", "C", 18);
        D = new MockERC20("D", "D", 18);
        Z = new MockERC20("Z", "Z", 18);
        pAD = _pool(A, D, 100 ether, 100 ether, 100);
        pAB = _pool(A, B, 10_000 ether, 10_000 ether, 30);
        pBD = _pool(B, D, 10_000 ether, 10_000 ether, 30);
        pAC = _pool(A, C, 1_000 ether, 1_000 ether, 30);
        pCD = _pool(C, D, 1_000 ether, 1_000 ether, 30);
        A.mint(user, 1_000 ether);
        vm.prank(user);
        A.approve(address(router), type(uint256).max);
    }

    function test_FindsDeepTwoHopRouteOverThinDirect() public view {
        MultiHopRouter.Route memory r = router.findBestRoute(address(A), address(D), 50 ether, 3);
        assertEq(r.pools.length, 2);
        assertEq(address(r.pools[0]), address(pAB));
        assertEq(address(r.pools[1]), address(pBD));
        assertEq(r.tokens[0], address(A));
        assertEq(r.tokens[1], address(B));
        assertEq(r.tokens[2], address(D));
        uint256 direct = pAD.getAmountOut(address(A), 50 ether);
        assertGt(r.amountOut, direct, "la ruta profunda debe ganarle al directo");
    }

    function test_MaxHopsOneOnlyDirect() public view {
        // Con maxHops = 1 el único candidato es el pool directo: la búsqueda respeta el límite
        // de saltos (útil para acotar gas o riesgo de contraparte en rutas largas).
        MultiHopRouter.Route memory r = router.findBestRoute(address(A), address(D), 0.001 ether, 1);
        assertEq(r.pools.length, 1);
        assertEq(address(r.pools[0]), address(pAD));
    }

    function test_SwapAlongPathMatchesQuote() public {
        SimplePool[] memory path = new SimplePool[](2);
        path[0] = pAB;
        path[1] = pBD;
        uint256 q = router.quotePath(path, address(A), 50 ether);
        vm.prank(user);
        uint256 out = router.swapAlongPath(path, address(A), address(D), 50 ether, q, user, block.timestamp);
        assertEq(out, q);
        assertEq(D.balanceOf(user), q);
        assertEq(A.balanceOf(address(router)), 0, "el router no retiene fondos");
        assertEq(B.balanceOf(address(router)), 0);
    }

    function test_SwapBestExecutesOptimalRoute() public {
        MultiHopRouter.Route memory r = router.findBestRoute(address(A), address(D), 50 ether, 3);
        vm.prank(user);
        uint256 out = router.swapBest(address(A), address(D), 50 ether, r.amountOut, 3, user, block.timestamp);
        assertEq(out, r.amountOut);
        assertEq(D.balanceOf(user), out);
    }

    function test_SlippageRevertsWholeRoute() public {
        SimplePool[] memory path = new SimplePool[](2);
        path[0] = pAB;
        path[1] = pBD;
        vm.prank(user);
        vm.expectRevert(MultiHopRouter.Slippage.selector);
        router.swapAlongPath(path, address(A), address(D), 50 ether, 60 ether, user, block.timestamp);
        assertEq(A.balanceOf(user), 1_000 ether, "atomicidad: no se movio nada");
    }

    function test_UnregisteredPoolRejected() public {
        SimplePool rogue = new SimplePool(IERC20(address(A)), IERC20(address(D)), 0);
        SimplePool[] memory path = new SimplePool[](1);
        path[0] = rogue;
        vm.prank(user);
        vm.expectRevert(MultiHopRouter.UnknownPool.selector);
        router.swapAlongPath(path, address(A), address(D), 1 ether, 0, user, block.timestamp);
    }

    function test_WrongTokenOutRejected() public {
        SimplePool[] memory path = new SimplePool[](1);
        path[0] = pAB;
        vm.prank(user);
        vm.expectRevert(MultiHopRouter.BadPath.selector);
        router.swapAlongPath(path, address(A), address(D), 1 ether, 0, user, block.timestamp);
    }

    function test_DeadlineRevert() public {
        vm.warp(100);
        SimplePool[] memory path = new SimplePool[](1);
        path[0] = pAD;
        vm.prank(user);
        vm.expectRevert(MultiHopRouter.Expired.selector);
        router.swapAlongPath(path, address(A), address(D), 1 ether, 0, user, 99);
    }

    function test_NoRouteToIsolatedToken() public {
        vm.prank(user);
        vm.expectRevert(MultiHopRouter.NoRoute.selector);
        router.swapBest(address(A), address(Z), 1 ether, 0, 4, user, block.timestamp);
    }

    function test_OnlyOwnerAddsPools() public {
        SimplePool p = new SimplePool(IERC20(address(A)), IERC20(address(Z)), 30);
        vm.prank(user);
        vm.expectRevert();
        router.addPool(p);
    }

    /// @notice Fuzz: la ruta elegida nunca es peor que cualquier ruta candidata conocida.
    function testFuzz_BestIsAtLeastAsGoodAsAlternatives(uint256 amt) public view {
        amt = bound(amt, 1e9, 500 ether);
        MultiHopRouter.Route memory r = router.findBestRoute(address(A), address(D), amt, 3);
        assertGe(r.amountOut, pAD.getAmountOut(address(A), amt));
        SimplePool[] memory p1 = new SimplePool[](2);
        p1[0] = pAB;
        p1[1] = pBD;
        SimplePool[] memory p2 = new SimplePool[](2);
        p2[0] = pAC;
        p2[1] = pCD;
        assertGe(r.amountOut, router.quotePath(p1, address(A), amt));
        assertGe(r.amountOut, router.quotePath(p2, address(A), amt));
    }
}
