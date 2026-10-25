// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SimpleNFT} from "../src/SimpleNFT.sol";

/// @title Tests del proyecto 30 — SimpleNFT
/// @notice Cubre mint, límites, metadata, revelado, retiro y permisos.
contract SimpleNFTTest is Test {
    SimpleNFT nft;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        nft = new SimpleNFT("Simple", "SMP", 10, 0.01 ether, "ipfs://oculto.json");
        nft.setSaleActive(true);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    /// @dev Necesario para que el test (dueño) pueda recibir ETH del withdraw.
    receive() external payable {}

    function test_MintBasico() public {
        vm.prank(alice);
        nft.mint{value: 0.02 ether}(2);
        assertEq(nft.balanceOf(alice), 2);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), alice);
        assertEq(nft.totalSupply(), 2);
        uint256[] memory ids = nft.tokensOfOwner(alice);
        assertEq(ids.length, 2);
    }

    function test_RevertPagoIncorrecto() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleNFT.WrongPayment.selector, 0.01 ether, 0.005 ether));
        nft.mint{value: 0.005 ether}(1);
    }

    function test_RevertVentaInactiva() public {
        nft.setSaleActive(false);
        vm.prank(alice);
        vm.expectRevert(SimpleNFT.SaleInactive.selector);
        nft.mint{value: 0.01 ether}(1);
    }

    function test_RevertLimitePorBilletera() public {
        vm.startPrank(alice);
        nft.mint{value: 0.05 ether}(5);
        vm.expectRevert(SimpleNFT.WalletLimit.selector);
        nft.mint{value: 0.01 ether}(1);
        vm.stopPrank();
    }

    function test_RevertAgotado() public {
        nft.ownerMint(bob, 9);
        vm.prank(alice);
        vm.expectRevert(SimpleNFT.SoldOut.selector);
        nft.mint{value: 0.02 ether}(2);
    }

    function test_MetadataRevelado() public {
        vm.prank(alice);
        nft.mint{value: 0.01 ether}(1);
        assertEq(nft.tokenURI(1), "ipfs://oculto.json");
        nft.reveal("ipfs://cid/");
        assertEq(nft.tokenURI(1), "ipfs://cid/1.json");
        vm.expectRevert(bytes("ya revelado"));
        nft.reveal("otra/");
    }

    function test_TokenURIInexistenteRevierte() public {
        vm.expectRevert();
        nft.tokenURI(99);
    }

    function test_Withdraw() public {
        vm.prank(alice);
        nft.mint{value: 0.03 ether}(3);
        uint256 antes = address(this).balance;
        nft.withdraw(payable(address(this)));
        assertEq(address(this).balance - antes, 0.03 ether);
    }

    function test_SoloDuenioRetira() public {
        vm.prank(alice);
        vm.expectRevert();
        nft.withdraw(payable(alice));
    }

    function test_Transferencia() public {
        vm.prank(alice);
        nft.mint{value: 0.01 ether}(1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
    }

    /// @notice Fuzz: cualquier cantidad válida acuña exactamente esa cantidad.
    function testFuzz_Mint(uint8 q) public {
        uint256 qty = bound(q, 1, 5);
        vm.prank(alice);
        nft.mint{value: 0.01 ether * qty}(qty);
        assertEq(nft.balanceOf(alice), qty);
    }
}
