// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VortexVault} from "../src/VortexVault.sol";
import {VortexDAO} from "../src/VortexDAO.sol";
import {MockERC20, MockOracle, MockAMM} from "../src/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VortexTest is Test {
    MockERC20 weth;
    MockERC20 usdc;
    MockOracle oracle;
    MockAMM amm;
    VortexVault vault;
    VortexDAO dao;
    address agent = makeAddr("agent");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address whale = makeAddr("whale");

    function _params() internal pure returns (VortexVault.Params memory) {
        return VortexVault.Params({
            minLpBps: 2_000,
            maxLpBps: 8_000,
            volK: 300_000, // 1% de vol ⇒ −30% de target
            aiBandBps: 1_000,
            maxSlippageBps: 100,
            maxDeviationBps: 200,
            maxTradeBps: 5_000,
            cooldown: 1 hours
        });
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.roll(100);
        weth = new MockERC20("Wrapped Ether", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");
        oracle = new MockOracle();
        oracle.setPrice(2000e18);
        amm = new MockAMM(IERC20(address(weth)), IERC20(address(usdc)));
        // liquidez externa profunda: 10k WETH / 20M USDC
        weth.mint(address(this), 10_000e18);
        usdc.mint(address(this), 20_000_000e18);
        weth.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.addLiquidity(10_000e18, 20_000_000e18);

        dao = new VortexDAO();
        vault = new VortexVault(
            IERC20(address(weth)), IERC20(address(usdc)), amm, oracle, address(dao), agent, guardian, _params()
        );
        dao.init(vault);

        usdc.mint(alice, 1_000_000e18);
        usdc.mint(bob, 1_000_000e18);
        usdc.mint(whale, 5_000_000e18);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100_000e18);
    }

    function _rebalance(uint256 t) internal {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(agent);
        vault.rebalance(t);
    }

    /// Volatilidad alta: el precio oscila ±3% por hora y termina donde empezó (AMM alineado).
    function _highVol(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.warp(block.timestamp + 1 hours);
            oracle.setPrice(i % 2 == 0 ? 2060e18 : 2000e18);
            vault.poke();
        }
    }

    function test_DepositAndNav() public view {
        assertEq(vault.nav(), 100_000e18);
        assertGt(vault.balanceOf(alice), 0);
        assertEq(vault.getVotes(alice), vault.balanceOf(alice));
    }

    function test_RebalanceUpInCappedSteps() public {
        assertEq(vault.policyTarget(), 8_000);
        _rebalance(8_000);
        assertApproxEqAbs(vault.lpAllocationBps(), 5_000, 100, "tope de 50% por paso");
        _rebalance(8_000);
        assertApproxEqAbs(vault.lpAllocationBps(), 8_000, 150);
        // el NAV no se pierde más allá de fees y slippage
        assertGt(vault.nav(), 99_500e18);
    }

    function test_HighVolatilityReducesLp() public {
        _rebalance(8_000);
        _rebalance(8_000);
        _highVol(10);
        assertGt(vault.volBps(), 200);
        assertEq(vault.policyTarget(), 2_000);
        _rebalance(2_000);
        _rebalance(2_000);
        assertApproxEqAbs(vault.lpAllocationBps(), 2_000, 150);
    }

    function test_AiFineTuneWithinBand() public {
        _rebalance(7_200); // política 8000, banda ±1000
        assertGt(vault.lpAllocationBps(), 4_000);
    }

    function test_RevertWhen_AiOutOfBand() public {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(VortexVault.AIOutOfBand.selector, 6_500, 8_000));
        vault.rebalance(6_500);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(VortexVault.AIOutOfBand.selector, 8_500, 8_000));
        vault.rebalance(8_500); // dentro de la banda pero sobre maxLp
    }

    function test_RevertWhen_NotAgentOrCooldown() public {
        vm.prank(alice);
        vm.expectRevert(VortexVault.OnlyAgent.selector);
        vault.rebalance(8_000);
        _rebalance(8_000);
        vm.prank(agent);
        vm.expectRevert(VortexVault.Cooldown.selector);
        vault.rebalance(8_000);
    }

    /// Un atacante mueve el AMM (sandwich o manipulación): el agente no puede operar y el NAV no se infla.
    function test_ManipulationGuard() public {
        _rebalance(8_000);
        uint256 navBefore = vault.nav();
        vm.startPrank(whale);
        usdc.approve(address(amm), type(uint256).max);
        amm.swap(address(usdc), 2_000_000e18, 0); // +~20% spot
        vm.stopPrank();
        assertApproxEqRel(vault.nav(), navBefore, 0.005e18, "fair LP pricing");
        vm.warp(block.timestamp + 1 hours);
        vm.prank(agent);
        vm.expectRevert();
        vault.rebalance(8_000);
    }

    function test_RedeemInKindEvenWhenPaused() public {
        _rebalance(8_000);
        vm.prank(guardian);
        vault.pause();
        vm.prank(bob);
        vm.expectRevert(VortexVault.IsPaused.selector);
        vault.deposit(1e18);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 u, uint256 w) = vault.redeem(shares);
        assertGt(w, 0);
        // valor recibido ≈ depósito (menos fees y slippage)
        assertApproxEqRel(u + w * 2000, 100_000e18, 0.01e18);
    }

    function test_PauseOnlyGuardianUnpauseOnlyDao() public {
        vm.prank(alice);
        vm.expectRevert(VortexVault.OnlyGuardian.selector);
        vault.pause();
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        vm.expectRevert(VortexVault.OnlyDao.selector);
        vault.unpause();
    }

    function _govern(bytes memory data) internal returns (uint256 id) {
        vm.roll(block.number + 1);
        vm.prank(alice);
        id = dao.propose(data);
        vm.prank(alice);
        dao.vote(id, true);
        vm.warp(block.timestamp + 3 days + 1);
        dao.queue(id);
        vm.warp(block.timestamp + 1 days);
    }

    function test_DaoChangesParams() public {
        VortexVault.Params memory p = _params();
        p.maxLpBps = 6_000;
        uint256 id = _govern(abi.encodeCall(VortexVault.setParams, (p)));
        dao.execute(id);
        assertEq(vault.policyTarget(), 6_000);
    }

    function test_DaoCannotBreakConstitution() public {
        VortexVault.Params memory p = _params();
        p.maxSlippageBps = 5_000; // 50%: abriría la puerta a robar vía sandwich
        uint256 id = _govern(abi.encodeCall(VortexVault.setParams, (p)));
        vm.expectRevert(VortexDAO.CallFailed.selector);
        dao.execute(id);
    }

    function test_RevertWhen_DaoArbitraryCall() public {
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(VortexDAO.BadSelector.selector);
        dao.propose(abi.encodeCall(IERC20.transfer, (alice, 1)));
    }

    function test_RevertWhen_DirectSetParams() public {
        vm.expectRevert(VortexVault.OnlyDao.selector);
        vault.setParams(_params());
    }

    function test_DaoReplacesAgent() public {
        address agent2 = makeAddr("agent2");
        uint256 id = _govern(abi.encodeCall(VortexVault.setAgent, (agent2)));
        dao.execute(id);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(agent);
        vm.expectRevert(VortexVault.OnlyAgent.selector);
        vault.rebalance(8_000);
        vm.prank(agent2);
        vault.rebalance(8_000);
    }

    function test_RevertWhen_PokeTooSoon() public {
        vm.expectRevert(VortexVault.TooSoon.selector);
        vault.poke();
    }

    /// Ataque de inflación clásico: con shares virtuales no es rentable.
    function test_InflationAttackUnprofitable() public {
        // vault nuevo y vacío
        VortexVault v2 = new VortexVault(
            IERC20(address(weth)), IERC20(address(usdc)), amm, oracle, address(dao), agent, guardian, _params()
        );
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 10_001e18);
        vm.startPrank(attacker);
        usdc.approve(address(v2), type(uint256).max);
        v2.deposit(1);
        usdc.transfer(address(v2), 10_000e18); // donación
        vm.stopPrank();
        vm.prank(bob);
        usdc.approve(address(v2), type(uint256).max);
        vm.prank(bob);
        uint256 s = v2.deposit(10_000e18);
        uint256 bobShares = s;
        vm.prank(bob);
        (uint256 out,) = v2.redeem(bobShares);
        assertGe(out, 9_990e18, "la victima no pierde");
    }
}
