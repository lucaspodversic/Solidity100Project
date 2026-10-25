// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RentVault} from "../src/RentVault.sol";
import {LeaseNFT} from "../src/LeaseNFT.sol";
import {MockUSD} from "../src/MockUSD.sol";

contract LeaseTest is Test {
    RentVault v;
    LeaseNFT nft;
    MockUSD usd;
    address landlord = makeAddr("landlord");
    address tenant = makeAddr("tenant");
    address arbiter = makeAddr("arbiter");
    address investor = makeAddr("investor");
    uint256 id;
    uint64 constant MONTH = 30 days;

    function setUp() public {
        vm.warp(1_700_000_000);
        usd = new MockUSD();
        v = new RentVault(usd, arbiter);
        nft = v.nft();
        vm.prank(landlord);
        id = nft.mint("ipfs://depto-2b");
        usd.mint(tenant, 100_000e18);
        vm.prank(tenant);
        usd.approve(address(v), type(uint256).max);
        // 12 meses × 1000, depósito 2000
        vm.prank(landlord);
        v.offer(id, tenant, 1000e18, MONTH, 12, 2000e18);
    }

    function _accept() internal {
        vm.prank(tenant);
        v.accept(id);
    }

    function test_AcceptGivesUsage() public {
        _accept();
        assertEq(nft.userOf(id), tenant);
        assertEq(nft.ownerOf(id), landlord);
        assertEq(usd.balanceOf(address(v)), 3000e18);
        assertTrue(nft.supportsInterface(0xad092b5c));
    }

    function test_RevertWhen_OtherAccepts() public {
        vm.prank(investor);
        vm.expectRevert(RentVault.NotTenant.selector);
        v.accept(id);
    }

    function test_RevertWhen_NonVaultSetsUser() public {
        vm.prank(landlord);
        vm.expectRevert(LeaseNFT.OnlyVault.selector);
        nft.setUser(id, landlord, type(uint64).max);
    }

    function test_UsageExpiresWithoutPayment() public {
        _accept();
        vm.warp(block.timestamp + MONTH + 3 days - 1);
        assertEq(nft.userOf(id), tenant, "en gracia");
        vm.warp(block.timestamp + 1);
        assertEq(nft.userOf(id), address(0), "corte automatico");
    }

    function test_PayRentExtendsUsage() public {
        _accept();
        vm.prank(tenant);
        v.payRent(id, 2);
        vm.warp(block.timestamp + 2 * MONTH + 10 days);
        assertEq(nft.userOf(id), tenant);
    }

    function test_ClaimOnlyStartedPeriods() public {
        _accept();
        vm.prank(tenant);
        v.payRent(id, 5); // 6 pagados
        assertEq(v.claimable(id), 1000e18); // solo el período 0 empezó
        vm.warp(block.timestamp + MONTH);
        assertEq(v.claimable(id), 2000e18);
        v.claimRent(id);
        assertEq(usd.balanceOf(landlord), 2000e18);
        assertEq(v.claimable(id), 0);
    }

    /// El flujo de renta sigue al NFT: vender el NFT = vender los ingresos.
    function test_RentFollowsNftOwner() public {
        _accept();
        vm.prank(tenant);
        v.payRent(id, 1);
        vm.prank(landlord);
        nft.transferFrom(landlord, investor, id);
        vm.warp(block.timestamp + MONTH);
        v.claimRent(id);
        assertEq(usd.balanceOf(investor), 2000e18);
        assertEq(nft.userOf(id), tenant, "el inquilino no se ve afectado");
    }

    function test_Evict() public {
        _accept();
        vm.prank(landlord);
        vm.expectRevert(RentVault.NotDelinquent.selector);
        v.evict(id);
        vm.warp(block.timestamp + MONTH + 3 days);
        vm.prank(landlord);
        v.evict(id);
        // 1000 renta del mes 0 + 1000 penalidad; 1000 del depósito vuelve
        assertEq(usd.balanceOf(landlord), 2000e18);
        assertEq(usd.balanceOf(tenant), 100_000e18 - 2000e18);
        assertEq(nft.userOf(id), address(0));
    }

    function _fullTerm() internal {
        _accept();
        vm.prank(tenant);
        v.payRent(id, 11);
        vm.warp(block.timestamp + 12 * MONTH);
        v.end(id);
    }

    function test_EndAndSettleWithoutClaim() public {
        _fullTerm();
        assertEq(usd.balanceOf(landlord), 12_000e18);
        vm.expectRevert(RentVault.WindowOpen.selector);
        v.settle(id);
        vm.warp(block.timestamp + 6 days + 1);
        v.settle(id);
        assertEq(usd.balanceOf(tenant), 100_000e18 - 12_000e18);
    }

    function test_DamageUndisputed() public {
        _fullTerm();
        vm.prank(landlord);
        v.claimDamage(id, 500e18, keccak256("fotos.zip"));
        vm.warp(block.timestamp + 6 days + 1);
        v.settle(id);
        assertEq(usd.balanceOf(landlord), 12_500e18);
        assertEq(usd.balanceOf(tenant), 100_000e18 - 12_500e18);
    }

    function test_DamageDisputedArbiterResolves() public {
        _fullTerm();
        vm.prank(landlord);
        v.claimDamage(id, 2000e18, keccak256("exagerado"));
        vm.prank(tenant);
        v.dispute(id);
        vm.expectRevert(RentVault.BadStatus.selector);
        v.settle(id);
        vm.prank(arbiter);
        v.resolve(id, 300e18);
        assertEq(usd.balanceOf(landlord), 12_300e18);
        assertEq(usd.balanceOf(tenant), 100_000e18 - 12_300e18);
    }

    function test_RevertWhen_DamageAboveDeposit() public {
        _fullTerm();
        vm.prank(landlord);
        vm.expectRevert(RentVault.BadTerms.selector);
        v.claimDamage(id, 2001e18, 0);
    }

    function test_RevertWhen_EndBeforeTerm() public {
        _accept();
        vm.expectRevert(RentVault.NotOver.selector);
        v.end(id);
    }

    function test_RevertWhen_OverpayPeriods() public {
        _accept();
        vm.prank(tenant);
        vm.expectRevert(RentVault.TooManyPeriods.selector);
        v.payRent(id, 12);
    }

    /// Invariante: el vault nunca libera más de lo que recibió.
    function testFuzz_Conservation(uint32 extra, uint32 jumpDays) public {
        extra = uint32(bound(extra, 0, 11));
        jumpDays = uint32(bound(jumpDays, 0, 400));
        _accept();
        if (extra > 0) {
            vm.prank(tenant);
            v.payRent(id, extra);
        }
        vm.warp(block.timestamp + uint256(jumpDays) * 1 days);
        v.claimRent(id);
        uint256 paidIn = 2000e18 + uint256(1 + extra) * 1000e18;
        assertEq(usd.balanceOf(landlord) + usd.balanceOf(address(v)), paidIn);
        assertLe(usd.balanceOf(landlord), uint256(1 + extra) * 1000e18);
    }
}
