// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {BadLogic, GoodLogic, SimpleProxy, InitLogic} from "../src/StorageClash.sol";

contract StorageTest is Test {
    address admin = makeAddr("admin");

    function test_ColisionSobrescribeAdmin() public {
        BadLogic logic = new BadLogic();
        SimpleProxy proxy = new SimpleProxy(address(logic), admin);
        assertEq(proxy.admin(), admin);

        // deposit via proxy → BadLogic.total (slot 0) pisa admin
        // total se lee como uint256(admin) y se le suma 1 ether → admin cambia
        BadLogic(payable(address(proxy))).deposit{value: 1 ether}();
        assertTrue(proxy.admin() != admin, "admin sobrescrito");
        // El slot 0 ahora vale uint160(admin)+1ether (truncado a address)
        assertEq(uint256(uint160(proxy.admin())), uint256(uint160(admin)) + 1 ether);
    }

    function test_GoodLogicNoPisaAdmin() public {
        GoodLogic logic = new GoodLogic();
        SimpleProxy proxy = new SimpleProxy(address(logic), admin);
        GoodLogic(payable(address(proxy))).deposit{value: 1 ether}();
        assertEq(proxy.admin(), admin); // intacto
        assertEq(GoodLogic(payable(address(proxy))).total(), 1 ether);
    }

    function test_InitFrontRun() public {
        InitLogic logic = new InitLogic();
        // Atacante front-runnea initialize antes que el deployer legítimo
        address atk = makeAddr("atk");
        vm.prank(atk); logic.initialize(atk);
        assertEq(logic.owner(), atk);
        vm.expectRevert(bytes("init"));
        logic.initialize(admin);
    }
}
