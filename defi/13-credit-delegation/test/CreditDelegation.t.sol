// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DelegatedLendingPool} from "../src/DelegatedLendingPool.sol";
import {CreditAgreement} from "../src/CreditAgreement.sol";
import {LendingPool} from "../src/protocol/LendingPool.sol";
import {JumpRateModel} from "../src/protocol/JumpRateModel.sol";
import {PriceOracle} from "../src/protocol/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @title Tests de delegación de crédito
contract CreditDelegationTest is Test {
    DelegatedLendingPool pool;
    PriceOracle oracle;
    CreditAgreement ca;
    MockERC20 usdc;
    MockERC20 weth;
    address lp = makeAddr("lp");
    uint256 delegatorPk = 0xA11CE;
    address delegator; // ballena con colateral
    address delegatee = makeAddr("delegatee"); // market maker sin colateral
    address stranger = makeAddr("stranger");

    function setUp() public {
        delegator = vm.addr(delegatorPk);
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        oracle = new PriceOracle();
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        JumpRateModel m = new JumpRateModel(0, 0.04e18, 0.75e18, 0.8e18);
        pool = new DelegatedLendingPool(oracle, makeAddr("treasury"));
        pool.listMarket(address(weth), 0.75e18, 0.8e18, 0.05e18, 0.1e18, m);
        pool.listMarket(address(usdc), 0.8e18, 0.85e18, 0.05e18, 0.1e18, m);
        ca = new CreditAgreement(pool);

        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 1_000_000e6);
        vm.stopPrank();

        weth.mint(delegator, 10e18); // 20 000 USD → puede pedir 15 000
        vm.startPrank(delegator);
        weth.approve(address(pool), type(uint256).max);
        pool.deposit(address(weth), 10e18);
        vm.stopPrank();

        usdc.mint(delegatee, 10_000e6);
        vm.prank(delegatee);
        usdc.approve(address(ca), type(uint256).max);
    }

    function test_DelegateeBorrowsDebtGoesToDelegator() public {
        vm.prank(delegator);
        pool.approveDelegation(address(usdc), delegatee, 5_000e6);
        vm.prank(delegatee);
        pool.borrowOnBehalf(address(usdc), 3_000e6, delegator);
        assertEq(usdc.balanceOf(delegatee), 13_000e6);
        assertEq(pool.borrowBalance(address(usdc), delegator), 3_000e6);
        assertEq(pool.borrowBalance(address(usdc), delegatee), 0);
        assertEq(pool.borrowAllowance(delegator, address(usdc), delegatee), 2_000e6);
    }

    function test_NoAllowanceReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DelegatedLendingPool.InsufficientAllowance.selector, 0, 1e6));
        pool.borrowOnBehalf(address(usdc), 1e6, delegator);
    }

    function test_AllowanceExceededReverts() public {
        vm.prank(delegator);
        pool.approveDelegation(address(usdc), delegatee, 1_000e6);
        vm.prank(delegatee);
        vm.expectRevert(abi.encodeWithSelector(DelegatedLendingPool.InsufficientAllowance.selector, 1_000e6, 1_001e6));
        pool.borrowOnBehalf(address(usdc), 1_001e6, delegator);
    }

    function test_DelegatorHealthLimitsDelegation() public {
        vm.prank(delegator);
        pool.approveDelegation(address(usdc), delegatee, type(uint256).max);
        vm.prank(delegatee);
        vm.expectRevert(LendingPool.InsufficientCollateral.selector);
        pool.borrowOnBehalf(address(usdc), 15_001e6, delegator);
    }

    function test_Revoke() public {
        vm.startPrank(delegator);
        pool.approveDelegation(address(usdc), delegatee, 1_000e6);
        pool.approveDelegation(address(usdc), delegatee, 0);
        vm.stopPrank();
        vm.prank(delegatee);
        vm.expectRevert();
        pool.borrowOnBehalf(address(usdc), 1, delegator);
    }

    function _sign(uint256 amount, uint256 nonce, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(pool.DELEGATION_TYPEHASH(), delegator, delegatee, address(usdc), amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", pool.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(delegatorPk, digest);
    }

    function test_DelegationWithSig() public {
        uint256 dl = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(2_000e6, 0, dl);
        vm.prank(stranger); // cualquiera puede relayear la firma
        pool.delegationWithSig(delegator, delegatee, address(usdc), 2_000e6, dl, v, r, s);
        assertEq(pool.borrowAllowance(delegator, address(usdc), delegatee), 2_000e6);
        // Replay: el nonce ya se consumió
        vm.expectRevert(DelegatedLendingPool.InvalidSignature.selector);
        pool.delegationWithSig(delegator, delegatee, address(usdc), 2_000e6, dl, v, r, s);
    }

    function test_DelegationWithSigExpired() public {
        uint256 t0 = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _sign(2_000e6, 0, t0 + 1);
        vm.warp(t0 + 2);
        vm.expectRevert(DelegatedLendingPool.ExpiredSignature.selector);
        pool.delegationWithSig(delegator, delegatee, address(usdc), 2_000e6, t0 + 1, v, r, s);
    }

    function test_TamperedSigReverts() public {
        uint256 dl = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(2_000e6, 0, dl);
        vm.expectRevert(DelegatedLendingPool.InvalidSignature.selector);
        pool.delegationWithSig(delegator, delegatee, address(usdc), 9_000e6, dl, v, r, s);
    }

    // ---------------- CreditAgreement ----------------

    function _agreement(uint256 limit) internal returns (uint256 id) {
        uint256 t0 = vm.getBlockTimestamp();
        vm.startPrank(delegator);
        pool.approveDelegation(address(usdc), address(ca), limit);
        id = ca.create(delegatee, address(usdc), limit, 1_000, uint64(t0 + 365 days)); // prima 10 %
        vm.stopPrank();
    }

    function test_AgreementDrawAndRepayWithPremium() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 id = _agreement(10_000e6);
        vm.prank(delegatee);
        ca.draw(id, 10_000e6);
        assertEq(pool.borrowBalance(address(usdc), delegator), 10_000e6);
        vm.warp(t0 + 182.5 days);
        assertApproxEqAbs(ca.premiumDue(id), 500e6, 1e6); // 10 % · medio año
        vm.prank(delegatee);
        ca.repay(id, 10_500e6);
        assertApproxEqAbs(usdc.balanceOf(delegator), 500e6, 1e6, "prima al delegador");
        // Solo queda el interés del pool (tasa baja con U ~1 %)
        assertLt(pool.borrowBalance(address(usdc), delegator), 10e6);
        (,,,,,,,,,, CreditAgreement.Status st) = ca.agreements(id);
        assertEq(uint256(st), uint256(CreditAgreement.Status.Repaid));
    }

    function test_AgreementLimitAndAuth() public {
        uint256 id = _agreement(1_000e6);
        vm.prank(stranger);
        vm.expectRevert(CreditAgreement.NotDelegatee.selector);
        ca.draw(id, 1);
        vm.prank(delegatee);
        vm.expectRevert(CreditAgreement.OverLimit.selector);
        ca.draw(id, 1_001e6);
    }

    function test_AgreementDefault() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 id = _agreement(1_000e6);
        vm.prank(delegatee);
        ca.draw(id, 1_000e6);
        vm.expectRevert(CreditAgreement.NotMatured.selector);
        ca.markDefault(id);
        vm.warp(t0 + 366 days);
        vm.prank(delegatee);
        vm.expectRevert(CreditAgreement.Matured.selector);
        ca.draw(id, 1);
        ca.markDefault(id);
        (,,,,,,,,,, CreditAgreement.Status st) = ca.agreements(id);
        assertEq(uint256(st), uint256(CreditAgreement.Status.Defaulted));
        // Aun en default se puede repagar (recupero)
        vm.prank(delegatee);
        ca.repay(id, 1_200e6);
    }

    function test_CancelOnlyWithoutOutstanding() public {
        uint256 id = _agreement(1_000e6);
        vm.prank(delegatee);
        ca.draw(id, 100e6);
        vm.prank(delegator);
        vm.expectRevert(CreditAgreement.Outstanding.selector);
        ca.cancel(id);
    }

    /// @notice Fuzz: la deuda del delegador nunca supera la allowance otorgada.
    function testFuzz_DebtBoundedByAllowance(uint256 allow, uint256 a1, uint256 a2) public {
        allow = bound(allow, 1, 15_000e6);
        a1 = bound(a1, 1, 15_000e6);
        a2 = bound(a2, 1, 15_000e6);
        vm.prank(delegator);
        pool.approveDelegation(address(usdc), delegatee, allow);
        vm.startPrank(delegatee);
        try pool.borrowOnBehalf(address(usdc), a1, delegator) {} catch {}
        try pool.borrowOnBehalf(address(usdc), a2, delegator) {} catch {}
        vm.stopPrank();
        assertLe(pool.borrowBalance(address(usdc), delegator), allow);
    }
}
