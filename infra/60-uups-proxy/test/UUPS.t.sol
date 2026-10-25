// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {VaultV1} from "../src/VaultV1.sol";
import {VaultV2} from "../src/VaultV2.sol";
import {NotUUPS} from "../src/NotUUPS.sol";

/// @title Tests del ciclo de vida UUPS
contract UUPSTest is Test {
    VaultV1 impl1;
    VaultV1 vault; // interfaz V1 sobre el proxy
    address admin = makeAddr("admin");
    address user = makeAddr("user");
    address attacker = makeAddr("attacker");

    function setUp() public {
        impl1 = new VaultV1();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl1), abi.encodeCall(VaultV1.initialize, (admin)));
        vault = VaultV1(address(proxy));
        vm.deal(user, 10 ether);
        vm.prank(user);
        vault.deposit{value: 4 ether}();
    }

    /// Estado inicial correcto a través del proxy.
    function test_InitialState() public view {
        assertEq(vault.owner(), admin);
        assertEq(vault.version(), "1.0.0");
        assertEq(vault.balanceOf(user), 4 ether);
        // el slot ERC-1967 apunta a la implementación
        bytes32 raw = vm.load(address(vault), ERC1967Utils.IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(raw))), address(impl1));
    }

    /// No se puede inicializar dos veces.
    function test_RevertWhen_ReInitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(attacker);
    }

    /// La implementación está bloqueada (_disableInitializers).
    function test_RevertWhen_InitializeImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl1.initialize(attacker);
    }

    /// Solo el owner puede actualizar.
    function test_RevertWhen_NonOwnerUpgrades() public {
        VaultV2 impl2 = new VaultV2();
        vm.prank(attacker);
        vm.expectRevert(VaultV1.NotOwner.selector);
        vault.upgradeToAndCall(address(impl2), "");
    }

    /// Upgrade a V2 conserva saldos y agrega funcionalidades.
    function test_UpgradePreservesState() public {
        VaultV2 impl2 = new VaultV2();
        vm.prank(admin);
        vault.upgradeToAndCall(address(impl2), abi.encodeCall(VaultV2.initializeV2, (100))); // 1%
        VaultV2 v2 = VaultV2(address(vault));
        assertEq(v2.version(), "2.0.0");
        assertEq(v2.balanceOf(user), 4 ether);   // estado de V1 intacto
        assertEq(v2.totalDeposits(), 4 ether);
        assertEq(v2.owner(), admin);
        assertEq(v2.feeBps(), 100);

        // retiro con comisión
        vm.prank(user);
        v2.withdraw(1 ether);
        assertEq(user.balance, 6 ether + 0.99 ether);
        assertEq(v2.feesAccrued(), 0.01 ether);

        // pausa
        vm.prank(admin);
        v2.setPaused(true);
        vm.prank(user);
        vm.expectRevert(VaultV2.IsPaused.selector);
        v2.withdraw(1 ether);

        // cobro de comisiones
        vm.prank(admin);
        v2.claimFees();
        assertEq(admin.balance, 0.01 ether);
    }

    /// initializeV2 no se puede correr dos veces.
    function test_RevertWhen_ReinitializeV2() public {
        VaultV2 impl2 = new VaultV2();
        vm.prank(admin);
        vault.upgradeToAndCall(address(impl2), abi.encodeCall(VaultV2.initializeV2, (100)));
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        VaultV2(address(vault)).initializeV2(200);
    }

    /// Upgrade a algo que no es UUPS revierte (evita congelar el proxy).
    function test_RevertWhen_UpgradeToNonUUPS() public {
        NotUUPS bad = new NotUUPS();
        vm.prank(admin);
        vm.expectRevert();
        vault.upgradeToAndCall(address(bad), "");
        assertEq(vault.version(), "1.0.0");
    }

    /// Llamar upgradeToAndCall directo en la implementación revierte (onlyProxy).
    function test_RevertWhen_UpgradeOnImplementationDirectly() public {
        VaultV2 impl2 = new VaultV2();
        vm.prank(admin);
        vm.expectRevert();
        impl1.upgradeToAndCall(address(impl2), "");
    }

    /// Comisión acotada.
    function test_RevertWhen_FeeTooHigh() public {
        VaultV2 impl2 = new VaultV2();
        vm.prank(admin);
        vm.expectRevert(VaultV2.FeeTooHigh.selector);
        vault.upgradeToAndCall(address(impl2), abi.encodeCall(VaultV2.initializeV2, (501)));
    }

    /// Transferencia de ownership afecta quién puede actualizar.
    function test_TransferOwnership() public {
        vm.prank(admin);
        vault.transferOwnership(user);
        VaultV2 impl2 = new VaultV2();
        vm.prank(admin);
        vm.expectRevert(VaultV1.NotOwner.selector);
        vault.upgradeToAndCall(address(impl2), "");
        vm.prank(user);
        vault.upgradeToAndCall(address(impl2), "");
        assertEq(vault.version(), "2.0.0");
    }

    /// Fuzz: depósitos/retiros mantienen la invariante totalDeposits.
    function testFuzz_DepositWithdraw(uint96 d, uint96 w) public {
        vm.deal(attacker, d);
        vm.prank(attacker);
        vault.deposit{value: d}();
        w = uint96(bound(w, 0, d));
        vm.prank(attacker);
        vault.withdraw(w);
        assertEq(vault.totalDeposits(), 4 ether + uint256(d) - uint256(w));
        assertEq(address(vault).balance, vault.totalDeposits());
    }
}
