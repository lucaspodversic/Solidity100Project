// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {LazyMintNFT} from "../src/LazyMintNFT.sol";

contract LazyMintTest is Test {
    LazyMintNFT nft;
    uint256 minterPk = 0xA11CE;
    address minter;
    address buyer = makeAddr("buyer");
    address creator;

    function setUp() public {
        minter = vm.addr(minterPk);
        creator = address(this);
        nft = new LazyMintNFT(minter);
        vm.deal(buyer, 5 ether);
    }
    receive() external payable {}

    function _sign(LazyMintNFT.Voucher memory v) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            nft.VOUCHER_TYPEHASH(), v.tokenId, v.price, v.buyer, keccak256(bytes(v.uri))
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", nft.domainSeparator(), structHash));
        (uint8 r, bytes32 s, bytes32 v_) = vm.sign(minterPk, digest);
        return abi.encodePacked(s, v_, r); // wait, order is r,s,v
    }

    function _signOk(LazyMintNFT.Voucher memory v) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            nft.VOUCHER_TYPEHASH(), v.tokenId, v.price, v.buyer, keccak256(bytes(v.uri))
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", nft.domainSeparator(), structHash));
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(minterPk, digest);
        return abi.encodePacked(rr, ss, vv);
    }

    function test_Redeem() public {
        LazyMintNFT.Voucher memory v = LazyMintNFT.Voucher({
            tokenId: 1, price: 0.1 ether, buyer: address(0), uri: "ipfs://x"
        });
        bytes memory sig = _signOk(v);
        uint256 c0 = creator.balance;
        vm.prank(buyer);
        nft.redeem{value: 0.1 ether}(v, sig);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(nft.tokenURI(1), "ipfs://x");
        assertEq(creator.balance - c0, 0.1 ether);
    }

    function test_ReplayBloqueado() public {
        LazyMintNFT.Voucher memory v = LazyMintNFT.Voucher(2, 0, address(0), "ipfs://y");
        bytes memory sig = _signOk(v);
        vm.prank(buyer); nft.redeem(v, sig);
        vm.prank(buyer);
        vm.expectRevert(LazyMintNFT.Used.selector);
        nft.redeem(v, sig);
    }

    function test_BuyerRestringido() public {
        LazyMintNFT.Voucher memory v = LazyMintNFT.Voucher(3, 0, buyer, "ipfs://z");
        bytes memory sig = _signOk(v);
        address otro = makeAddr("otro");
        vm.prank(otro);
        vm.expectRevert(LazyMintNFT.WrongBuyer.selector);
        nft.redeem(v, sig);
        vm.prank(buyer);
        nft.redeem(v, sig);
        assertEq(nft.ownerOf(3), buyer);
    }

    function test_BadSig() public {
        LazyMintNFT.Voucher memory v = LazyMintNFT.Voucher(4, 0, address(0), "ipfs://w");
        // firmamos con otra key
        uint256 badPk = 0xB0B;
        bytes32 structHash = keccak256(abi.encode(nft.VOUCHER_TYPEHASH(), v.tokenId, v.price, v.buyer, keccak256(bytes(v.uri))));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", nft.domainSeparator(), structHash));
        (uint8 vv, bytes32 rr, bytes32 ss) = vm.sign(badPk, digest);
        bytes memory sig = abi.encodePacked(rr, ss, vv);
        vm.prank(buyer);
        vm.expectRevert(LazyMintNFT.BadSig.selector);
        nft.redeem(v, sig);
    }
}
