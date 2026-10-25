// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UpgradeableTokenV1} from "../src/UpgradeableTokenV1.sol";
import {UpgradeableTokenV2} from "../src/UpgradeableTokenV2.sol";

contract UpgradeableTokenTest is Test {
    UpgradeableTokenV1 token; // la interfaz V1 apuntando al PROXY
    address proxy;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        UpgradeableTokenV1 impl = new UpgradeableTokenV1();
        // El proxy llama a initialize en el mismo despliegue (atómico: evita front-running).
        bytes memory init = abi.encodeCall(UpgradeableTokenV1.initialize, ("Nimbus Token", "NIM", owner, 1_000 ether));
        proxy = address(new ERC1967Proxy(address(impl), init));
        token = UpgradeableTokenV1(proxy);
    }

    function _erc7201(string memory ns) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(ns))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_SlotsERC7201() public pure {
        assertEq(_erc7201("fundamentos.storage.UpgradeableToken"), 0x9aab624d3eef1e56c7b749017cc7192d93497294bdb4adae84b15780e14a7900);
        assertEq(_erc7201("fundamentos.storage.UpgradeableTokenV2"), 0x5075c39e66d6f0232c0acd6c5eb977de01db2fdaa7bca08eb1fbaf15a4ff6700);
    }

    function test_EstadoInicial() public view {
        assertEq(token.name(), "Nimbus Token");
        assertEq(token.balanceOf(owner), 1_000 ether);
        assertEq(token.version(), "1");
    }

    function test_NoReinicializar() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize("X", "X", alice, 1);
    }

    function test_ImplementacionBloqueada() public {
        UpgradeableTokenV1 impl = new UpgradeableTokenV1();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize("X", "X", alice, 1);
    }

    function test_UpgradeConservaEstado() public {
        vm.prank(owner);
        token.transfer(alice, 100 ether);

        UpgradeableTokenV2 implV2 = new UpgradeableTokenV2();
        vm.prank(owner);
        token.upgradeToAndCall(address(implV2), abi.encodeCall(UpgradeableTokenV2.initializeV2, (2_000 ether)));

        UpgradeableTokenV2 t2 = UpgradeableTokenV2(proxy);
        // Misma dirección, mismos saldos, nueva lógica.
        assertEq(t2.version(), "2");
        assertEq(t2.balanceOf(alice), 100 ether);
        assertEq(t2.totalSupply(), 1_000 ether);
        assertEq(t2.cap(), 2_000 ether);

        vm.prank(alice);
        t2.burn(40 ether);
        assertEq(t2.totalSupply(), 960 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableTokenV2.CapExceeded.selector, 2_000 ether, 2_060 ether));
        t2.mintCapped(alice, 1_100 ether);
    }

    function test_SoloOwnerActualiza() public {
        UpgradeableTokenV2 implV2 = new UpgradeableTokenV2();
        vm.prank(alice);
        vm.expectRevert(UpgradeableTokenV1.NotOwner.selector);
        token.upgradeToAndCall(address(implV2), "");
    }

    function test_TransferFromConAllowance() public {
        vm.prank(owner);
        token.approve(alice, 50 ether);
        vm.prank(alice);
        token.transferFrom(owner, alice, 30 ether);
        assertEq(token.allowance(owner, alice), 20 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UpgradeableTokenV1.InsufficientAllowance.selector, 20 ether, 30 ether));
        token.transferFrom(owner, alice, 30 ether);
    }
}
