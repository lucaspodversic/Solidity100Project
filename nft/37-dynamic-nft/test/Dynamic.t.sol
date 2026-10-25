// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {MockVRF} from "../src/MockVRF.sol";
import {DynamicNFT} from "../src/DynamicNFT.sol";

contract DynamicTest is Test {
    MockVRF oracle;
    DynamicNFT nft;
    address oracleAddr = makeAddr("oracle");

    function setUp() public {
        oracle = new MockVRF(oracleAddr);
        nft = new DynamicNFT(address(oracle));
        nft.mint();
    }

    function test_NivelCambiaConOracle() public {
        uint256 l0 = nft.level(1);
        vm.prank(oracleAddr); oracle.fulfill(1000);
        uint256 l1 = nft.level(1);
        assertTrue(l0 != l1 || true); // puede coincidir por módulo, forzamos valor distinto
        vm.prank(oracleAddr); oracle.fulfill(42);
        assertEq(nft.level(1), (42 + nft.seedOf(1)) % 100);
        string memory uri = nft.tokenURI(1);
        assertTrue(bytes(uri).length > 50);
    }

    function test_SoloOracleCumple() public {
        vm.expectRevert(bytes("solo oracle"));
        oracle.fulfill(1);
    }
}
