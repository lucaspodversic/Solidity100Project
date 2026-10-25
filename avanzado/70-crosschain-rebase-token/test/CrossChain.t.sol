// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {Vault} from "../src/Vault.sol";
import {MockRouter} from "../src/MockRouter.sol";
import {TokenPool} from "../src/TokenPool.sol";

/// @notice "Cadena A" (Sepolia simulada) con vault y "cadena B" (Arbitrum simulada) sin vault.
contract CrossChainTest is Test {
    uint64 constant A = 1;
    uint64 constant B = 2;
    RebaseToken tA;
    RebaseToken tB;
    Vault vault;
    MockRouter router;
    TokenPool poolA;
    TokenPool poolB;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_700_000_000);
        router = new MockRouter();
        tA = new RebaseToken();
        tB = new RebaseToken();
        vault = new Vault(tA);
        poolA = new TokenPool(tA, router, A);
        poolB = new TokenPool(tB, router, B);
        tA.grantRole(tA.MINT_BURN_ROLE(), address(vault));
        tA.grantRole(tA.MINT_BURN_ROLE(), address(poolA));
        tB.grantRole(tB.MINT_BURN_ROLE(), address(poolB));
        poolA.setRemotePool(B, address(poolB));
        poolB.setRemotePool(A, address(poolA));
        vm.deal(alice, 100 ether);
        vm.deal(address(vault), 10 ether); // fondo de recompensas
    }

    function _lastMessageId() internal returns (bytes32 id) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MockRouter.MessageSent.selector) id = logs[i].topics[1];
        }
    }

    function test_BalanceGrowsLinearly() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        assertEq(tA.balanceOf(alice), 1 ether);
        vm.warp(block.timestamp + 1000);
        assertEq(tA.balanceOf(alice), 1 ether + 1 ether * 1e9 * 1000 / 1e18);
        vm.warp(block.timestamp + 1000);
        assertEq(tA.balanceOf(alice), 1 ether + 2 * (1 ether * 1e9 * 1000 / 1e18));
    }

    function test_RedeemWithInterest() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.warp(block.timestamp + 365 days);
        uint256 bal = tA.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(type(uint256).max);
        assertEq(alice.balance, 99 ether + bal);
        assertGt(bal, 1.03 ether);
    }

    function test_RateCanOnlyDecrease() public {
        tA.setGlobalRate(5e8);
        vm.expectRevert(abi.encodeWithSelector(RebaseToken.RateCanOnlyDecrease.selector, 5e8, 6e8));
        tA.setGlobalRate(6e8);
    }

    function test_EarlyDepositorKeepsRate() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        tA.setGlobalRate(1e8);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vault.deposit{value: 1 ether}();
        assertEq(tA.userRate(alice), 1e9);
        assertEq(tA.userRate(bob), 1e8);
    }

    function test_TransferInheritsRate() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        tA.setGlobalRate(1e8);
        vm.prank(alice);
        tA.transfer(bob, 0.5 ether);
        assertEq(tA.userRate(bob), 1e9);
    }

    function test_BridgePreservesRateAndInterest() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.warp(block.timestamp + 1 days);
        uint256 balBefore = tA.balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        poolA.bridge(B, alice, type(uint256).max);
        bytes32 id = _lastMessageId();
        assertEq(tA.balanceOf(alice), 0);
        // antes de la entrega no hay nada en B (latencia)
        assertEq(tB.balanceOf(alice), 0);
        router.deliver(id);
        assertEq(tB.balanceOf(alice), balBefore);
        assertEq(tB.userRate(alice), 1e9);
        // sigue rindiendo en la cadena B
        vm.warp(block.timestamp + 1 days);
        assertGt(tB.balanceOf(alice), balBefore);
    }

    function test_BridgeBackAndRedeem() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.recordLogs();
        vm.prank(alice);
        poolA.bridge(B, alice, type(uint256).max);
        router.deliver(_lastMessageId());
        vm.warp(block.timestamp + 10 days);
        vm.recordLogs();
        vm.prank(alice);
        poolB.bridge(A, alice, type(uint256).max);
        router.deliver(_lastMessageId());
        uint256 bal = tA.balanceOf(alice);
        assertGt(bal, 1 ether);
        vm.prank(alice);
        vault.redeem(type(uint256).max);
        assertEq(alice.balance, 99 ether + bal);
    }

    function test_RevertWhen_Replay() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.recordLogs();
        vm.prank(alice);
        poolA.bridge(B, alice, 1 ether);
        bytes32 id = _lastMessageId();
        router.deliver(id);
        vm.expectRevert(MockRouter.AlreadyDelivered.selector);
        router.deliver(id);
    }

    function test_RevertWhen_FakeRouterOrPool() public {
        bytes memory payload = abi.encode(bob, 1000 ether, 1e9);
        // llamada directa (no router)
        vm.expectRevert(TokenPool.OnlyRouter.selector);
        poolB.receiveMessage(bytes32(0), A, address(poolA), payload);
        // mensaje vía router desde un pool falso
        vm.recordLogs();
        router.send(A, B, address(poolB), payload); // sender = este test, no poolA
        bytes32 id = _lastMessageId();
        vm.expectRevert(TokenPool.UnknownRemote.selector);
        router.deliver(id);
    }

    function test_RevertWhen_UnknownDestination() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert(TokenPool.UnknownRemote.selector);
        poolA.bridge(99, alice, 1 ether);
    }

    /// No se puede "subir" la tasa trayendo tokens de alta tasa a una cuenta de baja tasa.
    function test_BridgeCannotRaiseExistingRate() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(); // alice: 1e9
        tA.setGlobalRate(1e8);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vault.deposit{value: 1 ether}(); // bob: 1e8
        // bob ya tiene RBT en B con tasa baja
        vm.recordLogs();
        vm.prank(bob);
        poolA.bridge(B, bob, 0.5 ether);
        router.deliver(_lastMessageId());
        assertEq(tB.userRate(bob), 1e8);
        // alice envía tokens de tasa alta a bob en B
        vm.recordLogs();
        vm.prank(alice);
        poolA.bridge(B, bob, 0.5 ether);
        router.deliver(_lastMessageId());
        assertEq(tB.userRate(bob), 1e8, "se queda con la menor");
    }

    function testFuzz_InterestMonotonic(uint96 amt, uint32 dt1, uint32 dt2) public {
        amt = uint96(bound(amt, 1e9, 50 ether));
        vm.prank(alice);
        vault.deposit{value: amt}();
        vm.warp(block.timestamp + dt1);
        uint256 b1 = tA.balanceOf(alice);
        vm.warp(block.timestamp + dt2);
        uint256 b2 = tA.balanceOf(alice);
        assertGe(b1, amt);
        assertGe(b2, b1);
    }
}
