// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {VaultLogic, TransparentProxy, VaultLogicSafe} from "../src/ProxyVault.sol";

contract AccessTest is Test {
    VaultLogic logic;
    TransparentProxy proxy;
    address admin = makeAddr("admin");
    address user = makeAddr("user");

    function setUp() public {
        logic = new VaultLogic();
        proxy = new TransparentProxy(address(logic), admin);
    }

    function _vault() internal view returns (VaultLogic) {
        return VaultLogic(payable(address(proxy)));
    }

    function test_ProxyDepositWithdraw() public {
        vm.deal(user, 2 ether);
        vm.prank(user); _vault().deposit{value: 1 ether}();
        assertEq(_vault().balances(user), 1 ether);
        vm.prank(user); _vault().withdraw(1 ether);
    }

    function test_SoloAdminUpgrade() public {
        VaultLogic newLogic = new VaultLogic();
        vm.prank(user);
        vm.expectRevert(bytes("admin"));
        proxy.upgrade(address(newLogic));
        vm.prank(admin); proxy.upgrade(address(newLogic));
        assertEq(proxy.implementation(), address(newLogic));
    }

    function test_LogicNakedInitializeTakeover() public {
        // Si alguien llama initialize en la lógica SIN proxy, toma admin del impl
        // (front-running de implementaciones no disableadas)
        address atk = makeAddr("atk");
        VaultLogic naked = new VaultLogic();
        vm.prank(atk); naked.initialize(atk);
        assertEq(naked.admin(), atk);
        // Safe: disableInitializers al deploy
        VaultLogicSafe s = new VaultLogicSafe();
        s.disableInitializers();
        vm.prank(atk);
        vm.expectRevert(bytes("init"));
        s.initialize(atk);
    }

    function test_AdminSweep() public {
        vm.deal(user, 3 ether);
        vm.prank(user); _vault().deposit{value: 3 ether}();
        vm.prank(admin); _vault().sweep(admin);
        assertEq(admin.balance, 3 ether);
    }
}
