// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {MockNFT} from "../src/MockNFT.sol";
import {FractionalNFT} from "../src/FractionalNFT.sol";

contract FractionalTest is Test {
    MockNFT nft;
    FractionalNFT vault;
    address buyer = makeAddr("buyer");

    function setUp() public {
        nft = new MockNFT();
        nft.mint(address(this), 7);
        vault = new FractionalNFT(address(nft), 7, 1000e18, "Frac", "FRAC");
        nft.approve(address(vault), 7);
        vault.deposit();
    }

    function test_Flujo() public {
        assertEq(nft.ownerOf(7), address(vault));
        vault.votePrice(1 ether);
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        vault.buy{value: 1 ether}();
        assertEq(nft.ownerOf(7), buyer);
        uint256 bal0 = address(this).balance;
        vault.redeem(500e18);
        assertEq(address(this).balance - bal0, 0.5 ether);
    }

    receive() external payable {}
}
