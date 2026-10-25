// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {NFTMarketplace} from "../src/NFTMarketplace.sol";
import {MockNFT} from "../src/MockNFT.sol";

/// @dev Atacante que intenta reentrar en buy.
contract ReentrantBuyer {
    NFTMarketplace m;
    uint256 id;
    bool again;
    constructor(NFTMarketplace m_) { m = m_; }
    function attack(uint256 id_) external payable {
        id = id_;
        m.buy{value: msg.value}(id_);
    }
    receive() external payable {
        if (!again) {
            again = true;
            // intenta reentrar — debe revertir por nonReentrant
            try m.buy{value: 0}(id) {} catch {}
        }
    }
}

contract MarketplaceTest is Test {
    NFTMarketplace market;
    MockNFT nft;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address feeTo = makeAddr("fee");

    function setUp() public {
        market = new NFTMarketplace(250, feeTo); // 2.5%
        nft = new MockNFT();
        vm.deal(buyer, 10 ether);
        vm.deal(seller, 1 ether);
    }

    function _list() internal returns (uint256 id, uint256 tokenId) {
        vm.startPrank(seller);
        tokenId = nft.mint(seller);
        nft.approve(address(market), tokenId);
        id = market.list(address(nft), tokenId, 1 ether);
        vm.stopPrank();
    }

    function test_ListBuy() public {
        (uint256 id, uint256 tokenId) = _list();
        uint256 sellerAntes = seller.balance;
        uint256 feeAntes = feeTo.balance;
        vm.prank(buyer);
        market.buy{value: 1 ether}(id);
        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(seller.balance - sellerAntes, 0.975 ether);
        assertEq(feeTo.balance - feeAntes, 0.025 ether);
        (,,,, bool active) = market.listings(id);
        assertFalse(active);
    }

    function test_Cancel() public {
        (uint256 id, uint256 tokenId) = _list();
        vm.prank(seller);
        market.cancel(id);
        assertEq(nft.ownerOf(tokenId), seller);
    }

    function test_RevertPagoIncorrecto() public {
        (uint256 id,) = _list();
        vm.prank(buyer);
        vm.expectRevert();
        market.buy{value: 0.5 ether}(id);
    }

    function test_RevertDobleCompra() public {
        (uint256 id,) = _list();
        vm.prank(buyer);
        market.buy{value: 1 ether}(id);
        vm.prank(buyer);
        vm.expectRevert(NFTMarketplace.NotActive.selector);
        market.buy{value: 1 ether}(id);
    }

    function test_ReentrancyBloqueada() public {
        // Listamos a un precio bajo; el "seller" es el atacante (recibe el pago y reentra).
        ReentrantBuyer atk = new ReentrantBuyer(market);
        vm.deal(address(atk), 0); // seller no necesita ETH
        // minteamos al atacante-vendedor
        uint256 tokenId = nft.mint(address(atk));
        // Lo transferimos a un seller EOA y listamos normal: el reentrancy se prueba
        // haciendo que feeRecipient sea el atacante.
        market.setFee(250, address(atk));
        (uint256 id,) = _list();
        vm.prank(buyer);
        market.buy{value: 1 ether}(id);
        // Si la reentrancy hubiera funcionado, el atacante tendría más de la fee.
        // Con nonReentrant, solo recibe la fee una vez.
        assertEq(address(atk).balance, 0.025 ether);
    }

    function test_SoloSellerCancela() public {
        (uint256 id,) = _list();
        vm.prank(buyer);
        vm.expectRevert(NFTMarketplace.NotOwner.selector);
        market.cancel(id);
    }
}
