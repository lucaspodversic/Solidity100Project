// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vendor} from "../src/Vendor.sol";
import {VendorToken} from "../src/VendorToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VendorTest is Test {
    VendorToken token;
    Vendor vendor;
    address owner = address(this);
    address alice = makeAddr("alice");

    // El test actúa como dueño: necesita poder recibir ETH en withdraw().
    receive() external payable {}

    function setUp() public {
        token = new VendorToken(1_000 ether);
        vendor = new Vendor(token);
        // El dueño carga el inventario completo en el vendor.
        token.transfer(address(vendor), 1_000 ether);
        vm.deal(alice, 10 ether);
    }

    function test_Comprar() public {
        vm.prank(alice);
        uint256 out = vendor.buyTokens{value: 1 ether}();
        assertEq(out, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(address(vendor).balance, 1 ether);
    }

    function test_RevertSinInventario() public {
        vm.deal(alice, 20 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vendor.InsufficientTokenInventory.selector, 1_000 ether, 2_000 ether));
        vendor.buyTokens{value: 20 ether}();
    }

    function test_VenderConApprove() public {
        vm.startPrank(alice);
        vendor.buyTokens{value: 2 ether}();
        token.approve(address(vendor), 100 ether);
        uint256 before = alice.balance;
        uint256 eth = vendor.sellTokens(100 ether);
        vm.stopPrank();
        assertEq(eth, 1 ether);
        assertEq(alice.balance, before + 1 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_RevertVenderSinApprove() public {
        vm.startPrank(alice);
        vendor.buyTokens{value: 1 ether}();
        vm.expectRevert(); // ERC20InsufficientAllowance
        vendor.sellTokens(100 ether);
        vm.stopPrank();
    }

    function test_RevertSinLiquidezEth() public {
        // Le damos tokens a alice por fuera del vendor (el vendor no tiene ETH).
        VendorToken t2 = new VendorToken(1_000 ether);
        Vendor v2 = new Vendor(t2);
        t2.transfer(alice, 100 ether);
        vm.startPrank(alice);
        t2.approve(address(v2), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Vendor.InsufficientEthLiquidity.selector, 0, 1 ether));
        v2.sellTokens(100 ether);
        vm.stopPrank();
    }

    function test_WithdrawSoloOwner() public {
        vm.prank(alice);
        vendor.buyTokens{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vendor.withdraw();
        uint256 before = owner.balance;
        vendor.withdraw();
        assertEq(owner.balance, before + 1 ether);
    }

    function testFuzz_CompraVentaIdaVuelta(uint64 wei_) public {
        vm.assume(wei_ > 0 && wei_ <= 10 ether);
        vm.startPrank(alice);
        uint256 out = vendor.buyTokens{value: wei_}();
        token.approve(address(vendor), out);
        uint256 back = vendor.sellTokens(out);
        vm.stopPrank();
        // Ida y vuelta al mismo precio fijo: se recupera exactamente lo pagado.
        assertEq(back, wei_);
    }
}
