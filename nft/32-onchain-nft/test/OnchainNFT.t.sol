// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {OnchainNFT} from "../src/OnchainNFT.sol";

contract OnchainNFTTest is Test {
    OnchainNFT nft;
    function setUp() public { nft = new OnchainNFT(5); }

    function test_MintYURI() public {
        uint256 id = nft.mint();
        assertEq(id, 1);
        string memory uri = nft.tokenURI(1);
        // Debe empezar con data:application/json;base64,
        assertTrue(bytes(uri).length > 100);
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory u = bytes(uri);
        for (uint i; i < prefix.length; ++i) assertEq(u[i], prefix[i]);
    }

    function test_Agotado() public {
        for (uint i; i < 5; ++i) nft.mint();
        vm.expectRevert(bytes("agotado"));
        nft.mint();
    }

    function test_SemillasDistintas() public {
        nft.mint();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        nft.mint();
        assertTrue(nft.seedOf(1) != nft.seedOf(2));
    }
}
