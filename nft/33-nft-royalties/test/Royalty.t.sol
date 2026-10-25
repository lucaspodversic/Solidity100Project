// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {RoyaltyNFT} from "../src/RoyaltyNFT.sol";
import {RoyaltyMarketplace} from "../src/RoyaltyMarketplace.sol";

contract RoyaltyTest is Test {
    RoyaltyNFT nft;
    RoyaltyMarketplace market;
    address creator = makeAddr("creator");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    function setUp() public {
        nft = new RoyaltyNFT(creator, 500); // 5%
        market = new RoyaltyMarketplace();
        vm.deal(buyer, 5 ether);
        uint256 id = nft.mint(seller);
        vm.prank(seller); nft.approve(address(market), id);
    }

    function test_RoyaltyInfo() public view {
        (address r, uint256 amt) = nft.royaltyInfo(1, 1 ether);
        assertEq(r, creator);
        assertEq(amt, 0.05 ether);
    }

    function test_CompraPagaRoyalty() public {
        vm.prank(seller);
        uint256 lid = market.list(address(nft), 1, 1 ether);
        uint256 c0 = creator.balance;
        uint256 s0 = seller.balance;
        vm.prank(buyer);
        market.buy{value: 1 ether}(lid);
        assertEq(creator.balance - c0, 0.05 ether);
        assertEq(seller.balance - s0, 0.95 ether);
        assertEq(nft.ownerOf(1), buyer);
    }

    function test_SupportsInterface() public view {
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC2981
    }
}
