// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {SolidityMarket} from "../src/SolidityMarket.sol";
import {AsmMarket} from "../src/AsmMarket.sol";

/// @dev NFT de prueba.
contract TestNFT is ERC721 {
    constructor() ERC721("Test", "TST") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// @dev Vendedor malicioso que intenta reentrar al recibir el pago.
contract EvilSeller {
    AsmMarket m;
    TestNFT nft;
    bool public reentered;
    constructor(AsmMarket _m, TestNFT _n) { m = _m; nft = _n; }
    function listIt(uint256 id, uint96 price) external {
        nft.setApprovalForAll(address(m), true);
        m.list(address(nft), id, price);
    }
    receive() external payable {
        try m.buy{value: 1}(address(nft), 999) { reentered = true; } catch {}
    }
}

/// @title Tests funcionales, de seguridad y comparación de gas
contract MarketsTest is Test {
    TestNFT nft;
    SolidityMarket sm;
    AsmMarket am;
    address fee = makeAddr("fee");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    function setUp() public {
        nft = new TestNFT();
        sm = new SolidityMarket(fee);
        am = new AsmMarket(fee);
        for (uint256 i = 1; i <= 10; i++) nft.mint(seller, i);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(sm), true);
        nft.setApprovalForAll(address(am), true);
        vm.stopPrank();
        vm.deal(buyer, 100 ether);
    }

    // ---------- funcionalidad del marketplace en assembly ----------

    function test_ListAndBuy() public {
        vm.prank(seller);
        am.list(address(nft), 1, 1 ether);
        (address s, uint256 p) = am.getListing(address(nft), 1);
        assertEq(s, seller);
        assertEq(p, 1 ether);
        vm.prank(buyer);
        am.buy{value: 1 ether}(address(nft), 1);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(seller.balance, 0.975 ether);
        assertEq(am.accruedFees(), 0.025 ether);
        am.withdrawFees();
        assertEq(fee.balance, 0.025 ether);
        (s,) = am.getListing(address(nft), 1);
        assertEq(s, address(0));
    }

    function test_RevertWhen_NotOwnerLists() public {
        vm.prank(buyer);
        vm.expectRevert(AsmMarket.NotOwner.selector);
        am.list(address(nft), 1, 1 ether);
    }

    function test_RevertWhen_NotApproved() public {
        nft.mint(buyer, 50);
        vm.prank(buyer);
        vm.expectRevert(AsmMarket.NotApproved.selector);
        am.list(address(nft), 50, 1 ether);
    }

    function test_SingleTokenApprovalWorks() public {
        nft.mint(buyer, 51);
        vm.startPrank(buyer);
        nft.approve(address(am), 51);
        am.list(address(nft), 51, 1 ether);
        vm.stopPrank();
        (address s,) = am.getListing(address(nft), 51);
        assertEq(s, buyer);
    }

    function test_RevertWhen_ZeroPrice() public {
        vm.prank(seller);
        vm.expectRevert(AsmMarket.ZeroPrice.selector);
        am.list(address(nft), 1, 0);
    }

    function test_RevertWhen_WrongPrice() public {
        vm.prank(seller);
        am.list(address(nft), 1, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(AsmMarket.WrongPrice.selector);
        am.buy{value: 0.5 ether}(address(nft), 1);
    }

    function test_RevertWhen_NotListed() public {
        vm.prank(buyer);
        vm.expectRevert(AsmMarket.NotListed.selector);
        am.buy{value: 1 ether}(address(nft), 7);
    }

    function test_Cancel() public {
        vm.prank(seller);
        am.list(address(nft), 1, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(AsmMarket.NotOwner.selector);
        am.cancel(address(nft), 1);
        vm.prank(seller);
        am.cancel(address(nft), 1);
        vm.prank(buyer);
        vm.expectRevert(AsmMarket.NotListed.selector);
        am.buy{value: 1 ether}(address(nft), 1);
    }

    /// Listado obsoleto: el vendedor transfirió el NFT por fuera => la compra revierte.
    function test_StaleListingReverts() public {
        vm.prank(seller);
        am.list(address(nft), 1, 1 ether);
        vm.prank(seller);
        nft.transferFrom(seller, makeAddr("other"), 1);
        vm.prank(buyer);
        vm.expectRevert();
        am.buy{value: 1 ether}(address(nft), 1);
        assertEq(buyer.balance, 100 ether);
    }

    /// Reentrada desde el vendedor bloqueada por el lock transitorio.
    function test_ReentrancyBlocked() public {
        EvilSeller evil = new EvilSeller(am, nft);
        nft.mint(address(evil), 999);
        nft.mint(address(evil), 77);
        evil.listIt(77, 1 ether);
        evil.listIt(999, 1);
        vm.prank(buyer);
        am.buy{value: 1 ether}(address(nft), 77);
        assertFalse(evil.reentered());
        assertEq(nft.ownerOf(77), buyer);
    }

    /// Los eventos emitidos en assembly son decodificables con el ABI normal.
    function test_EventTopicsMatch() public {
        vm.expectEmit(true, true, true, true, address(am));
        emit AsmMarket.Listed(address(nft), 3, seller, 2 ether);
        vm.prank(seller);
        am.list(address(nft), 3, 2 ether);
        vm.expectEmit(true, true, true, true, address(am));
        emit AsmMarket.Sold(address(nft), 3, buyer, 2 ether);
        vm.prank(buyer);
        am.buy{value: 2 ether}(address(nft), 3);
        vm.prank(seller);
        am.list(address(nft), 4, 1 ether);
        vm.expectEmit(true, true, false, false, address(am));
        emit AsmMarket.Cancelled(address(nft), 4);
        vm.prank(seller);
        am.cancel(address(nft), 4);
    }

    // ---------- diferencial: ambos mercados se comportan igual ----------

    function testFuzz_Differential(uint96 price, uint8 idRaw) public {
        price = uint96(bound(price, 1, 50 ether));
        uint256 id = bound(idRaw, 1, 5);
        vm.startPrank(seller);
        sm.list(address(nft), id, price);
        am.list(address(nft), id + 5, price);
        vm.stopPrank();
        (address s1, uint256 p1) = sm.getListing(address(nft), id);
        (address s2, uint256 p2) = am.getListing(address(nft), id + 5);
        assertEq(s1, s2);
        assertEq(p1, p2);
        vm.startPrank(buyer);
        sm.buy{value: price}(address(nft), id);
        am.buy{value: price}(address(nft), id + 5);
        vm.stopPrank();
        assertEq(sm.accruedFees(), am.accruedFees());
        assertEq(nft.ownerOf(id), nft.ownerOf(id + 5));
    }

    // ---------- comparación de gas ----------

    function test_GasComparison() public {
        vm.startPrank(seller);
        uint256 g = gasleft(); sm.list(address(nft), 1, 1 ether); uint256 gListS = g - gasleft();
        g = gasleft(); am.list(address(nft), 2, 1 ether); uint256 gListA = g - gasleft();
        vm.stopPrank();
        vm.startPrank(buyer);
        g = gasleft(); sm.buy{value: 1 ether}(address(nft), 1); uint256 gBuyS = g - gasleft();
        g = gasleft(); am.buy{value: 1 ether}(address(nft), 2); uint256 gBuyA = g - gasleft();
        vm.stopPrank();
        console2.log("list  Solidity:", gListS, " Assembly:", gListA);
        console2.log("buy   Solidity:", gBuyS, " Assembly:", gBuyA);
        assertLt(gListA, gListS);
        assertLt(gBuyA, gBuyS);
    }
}
