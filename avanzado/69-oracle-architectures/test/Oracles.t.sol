// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IOracle} from "../src/IOracle.sol";
import {WhitelistOracle} from "../src/WhitelistOracle.sol";
import {StakingOracle} from "../src/StakingOracle.sol";
import {OptimisticOracle} from "../src/OptimisticOracle.sol";
import {PriceConsumer} from "../src/PriceConsumer.sol";

contract WhitelistOracleTest is Test {
    WhitelistOracle o;
    address[5] r;

    function setUp() public {
        vm.warp(1_700_000_000);
        o = new WhitelistOracle(1 hours, 3);
        for (uint256 i = 0; i < 5; i++) {
            r[i] = address(uint160(0x100 + i));
            o.addReporter(r[i]);
        }
    }

    function _rep(uint256 i, uint256 v) internal {
        vm.prank(r[i]);
        o.report(v);
    }

    function test_MedianOfReports() public {
        _rep(0, 2000);
        _rep(1, 2010);
        _rep(2, 1990);
        _rep(3, 2005);
        _rep(4, 1995);
        (uint256 v,) = o.latest();
        assertEq(v, 2000);
    }

    function test_ToleratesMinorityOfLiars() public {
        _rep(0, 2000);
        _rep(1, 2001);
        _rep(2, 1999);
        _rep(3, 1); // mentiroso
        _rep(4, 1e30); // mentiroso
        (uint256 v,) = o.latest();
        assertEq(v, 2000);
    }

    function test_RevertWhen_NoQuorum() public {
        _rep(0, 2000);
        _rep(1, 2000);
        vm.expectRevert(WhitelistOracle.NoQuorum.selector);
        o.latest();
    }

    function test_StaleReportsIgnored() public {
        _rep(0, 2000);
        _rep(1, 2000);
        vm.warp(block.timestamp + 2 hours);
        _rep(2, 3000);
        _rep(3, 3000);
        _rep(4, 3000);
        (uint256 v,) = o.latest();
        assertEq(v, 3000);
    }

    function test_RevertWhen_NotReporter() public {
        vm.expectRevert(WhitelistOracle.NotReporter.selector);
        o.report(1);
    }

    function test_RemoveReporter() public {
        o.removeReporter(r[0]);
        vm.prank(r[0]);
        vm.expectRevert(WhitelistOracle.NotReporter.selector);
        o.report(1);
    }
}

contract StakingOracleTest is Test {
    StakingOracle o;
    address[5] r;

    function setUp() public {
        vm.warp(1_700_000_000);
        o = new StakingOracle();
        for (uint256 i = 0; i < 5; i++) {
            r[i] = address(uint160(0x200 + i));
            vm.deal(r[i], 10 ether);
            vm.prank(r[i]);
            o.stake{value: 2 ether}();
        }
    }

    function _rep(uint256 i, uint256 v) internal {
        vm.prank(r[i]);
        o.report(v);
    }

    function test_FinalizeAndSlash() public {
        uint256 e = o.currentEpoch();
        _rep(0, 2000);
        _rep(1, 2002);
        _rep(2, 1998);
        _rep(3, 2500); // outlier
        _rep(4, 2001);
        vm.expectRevert(StakingOracle.EpochNotOver.selector);
        o.finalize(e);
        vm.warp(block.timestamp + 1 hours);
        o.finalize(e);
        (uint256 v,) = o.latest();
        assertEq(v, 2001);
        (uint256 st,) = o.stakers(r[3]);
        assertEq(st, 1.8 ether);
        assertEq(o.rewards(r[0]), 0.05 ether); // 0.2 / 4
        vm.expectRevert(StakingOracle.AlreadyFinalized.selector);
        o.finalize(e);
    }

    function test_RevertWhen_DoubleReport() public {
        _rep(0, 1);
        vm.prank(r[0]);
        vm.expectRevert(StakingOracle.AlreadyReported.selector);
        o.report(2);
    }

    function test_RevertWhen_NotEnoughStake() public {
        address x = makeAddr("x");
        vm.deal(x, 1 ether);
        vm.prank(x);
        vm.expectRevert(StakingOracle.InsufficientStake.selector);
        o.stake{value: 0.5 ether}();
    }

    function test_RevertWhen_NotEnoughReports() public {
        uint256 e = o.currentEpoch();
        _rep(0, 1);
        _rep(1, 1);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(StakingOracle.NotEnoughReports.selector);
        o.finalize(e);
    }

    function test_UnbondingFlow() public {
        vm.prank(r[0]);
        o.requestUnbond();
        vm.prank(r[0]);
        vm.expectRevert(StakingOracle.Unbonding.selector);
        o.report(1);
        vm.prank(r[0]);
        vm.expectRevert(StakingOracle.NotReady.selector);
        o.withdraw();
        vm.warp(block.timestamp + 2 days);
        vm.prank(r[0]);
        o.withdraw();
        assertEq(r[0].balance, 10 ether);
    }

    /// Ataque de mayoría: 3 de 5 mienten → mueven la mediana y los honestos son slasheados.
    /// Demuestra el límite de seguridad (necesitan > 50% del conjunto de la época).
    function test_MajorityAttackSucceeds_DocumentedLimit() public {
        uint256 e = o.currentEpoch();
        _rep(0, 2000);
        _rep(1, 2000);
        _rep(2, 9999);
        _rep(3, 9999);
        _rep(4, 9999);
        vm.warp(block.timestamp + 1 hours);
        o.finalize(e);
        (uint256 v,) = o.latest();
        assertEq(v, 9999);
    }
}

contract OptimisticOracleTest is Test {
    OptimisticOracle o;
    address arb = makeAddr("arb");
    address prop = makeAddr("prop");
    address disp = makeAddr("disp");

    function setUp() public {
        vm.warp(1_700_000_000);
        o = new OptimisticOracle(arb);
        vm.deal(prop, 10 ether);
        vm.deal(disp, 10 ether);
    }

    function test_UndisputedSettles() public {
        vm.prank(prop);
        uint256 id = o.propose{value: 1 ether}(2000);
        vm.expectRevert(OptimisticOracle.LivenessNotOver.selector);
        o.settle(id);
        vm.warp(block.timestamp + 2 hours);
        o.settle(id);
        (uint256 v,) = o.latest();
        assertEq(v, 2000);
        vm.prank(prop);
        o.claim();
        assertEq(prop.balance, 10 ether);
    }

    function test_DisputeProposerLoses() public {
        vm.prank(prop);
        uint256 id = o.propose{value: 1 ether}(9999); // mentira
        vm.prank(disp);
        o.dispute{value: 1 ether}(id);
        vm.expectRevert(OptimisticOracle.BadState.selector);
        o.settle(id);
        vm.prank(arb);
        o.resolve(id, false, 2000);
        (uint256 v,) = o.latest();
        assertEq(v, 2000);
        vm.prank(disp);
        o.claim();
        assertEq(disp.balance, 10.9 ether); // +1 ETH del mentiroso − 10% fee
        assertEq(prop.balance, 9 ether);
    }

    function test_DisputeProposerWins() public {
        vm.prank(prop);
        uint256 id = o.propose{value: 1 ether}(2000);
        vm.prank(disp);
        o.dispute{value: 1 ether}(id); // disputa frívola
        vm.prank(arb);
        o.resolve(id, true, 0);
        vm.prank(prop);
        o.claim();
        assertEq(prop.balance, 10.9 ether);
    }

    function test_RevertWhen_DisputeAfterLiveness() public {
        vm.prank(prop);
        uint256 id = o.propose{value: 1 ether}(2000);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(disp);
        vm.expectRevert(OptimisticOracle.LivenessOver.selector);
        o.dispute{value: 1 ether}(id);
    }

    function test_RevertWhen_WrongBondOrNotArbitrator() public {
        vm.prank(prop);
        vm.expectRevert(OptimisticOracle.WrongBond.selector);
        o.propose{value: 0.5 ether}(1);
        vm.prank(prop);
        uint256 id = o.propose{value: 1 ether}(1);
        vm.prank(disp);
        o.dispute{value: 1 ether}(id);
        vm.expectRevert(OptimisticOracle.NotArbitrator.selector);
        o.resolve(id, true, 0);
    }
}

/// El mismo consumidor funciona con las tres arquitecturas y rechaza datos viejos.
contract ConsumerTest is Test {
    function test_ConsumerWithAllOracles() public {
        vm.warp(1_700_000_000);
        // whitelist
        WhitelistOracle w = new WhitelistOracle(1 hours, 1);
        w.addReporter(address(this));
        w.report(2000);
        assertEq(new PriceConsumer(IOracle(address(w)), 1 hours).price(), 2000);
        // optimista
        OptimisticOracle op = new OptimisticOracle(address(1));
        op.propose{value: 1 ether}(2100);
        vm.warp(block.timestamp + 2 hours);
        op.settle(0);
        PriceConsumer c = new PriceConsumer(IOracle(address(op)), 3 hours);
        assertEq(c.price(), 2100);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(PriceConsumer.Stale.selector);
        c.price();
    }
}
