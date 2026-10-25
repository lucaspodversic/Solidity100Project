// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {DAOVault} from "../src/DAOVault.sol";
import {MockStrategy} from "../src/MockStrategy.sol";

contract VaultTest is Test {
    MockERC20 asset; DAOVault vault; MockStrategy strat;
    address gov = makeAddr("gov");
    address user = makeAddr("user");

    function setUp() public {
        asset = new MockERC20();
        vault = new DAOVault(address(asset), gov, 100, 10000e18);
        strat = new MockStrategy(address(asset));
        asset.mint(user, 1000e18);
        vm.prank(user); asset.approve(address(vault), type(uint256).max);
    }

    function test_DepositWithdraw() public {
        vm.prank(user); vault.deposit(100e18);
        assertEq(vault.shares(user), 100e18);
        vm.prank(user); vault.withdraw(50e18);
        assertEq(asset.balanceOf(user), 950e18);
    }

    function test_SoloGovParams() public {
        vm.expectRevert(DAOVault.OnlyGov.selector);
        vault.setParams(50, 1);
        vm.prank(gov); vault.setParams(50, 5000e18);
        assertEq(vault.feeBps(), 50);
    }

    function test_Strategy() public {
        vm.prank(gov); vault.setStrategy(address(strat));
        vm.prank(user); vault.deposit(200e18);
        vm.prank(gov); vault.allocate(100e18);
        assertEq(strat.totalManaged(), 100e18);
        assertEq(vault.totalAssets(), 200e18);
    }
}
