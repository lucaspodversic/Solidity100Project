// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PropertyRegistry} from "../src/PropertyRegistry.sol";
import {PropertyShares} from "../src/PropertyShares.sol";
import {PropertyDAO} from "../src/PropertyDAO.sol";

contract RealEstateTest is Test {
    PropertyRegistry reg;
    PropertyShares sh;
    PropertyDAO dao;
    address registrar = makeAddr("registrar");
    address alice = makeAddr("alice"); // 60%
    address bob = makeAddr("bob"); // 30%
    address carol = makeAddr("carol"); // 10%
    address tenant = makeAddr("tenant");
    address buyer = makeAddr("buyer");
    address mallory = makeAddr("mallory"); // sin KYC
    uint256 pid;

    function setUp() public {
        reg = new PropertyRegistry(registrar);
        dao = new PropertyDAO(reg, 1);
        vm.startPrank(registrar);
        reg.setVerified(alice, true);
        reg.setVerified(bob, true);
        reg.setVerified(carol, true);
        pid = reg.mintProperty(address(dao), keccak256("escritura.pdf"), "ipfs://casa", 300 ether);
        vm.stopPrank();
        address[] memory h = new address[](3);
        h[0] = alice;
        h[1] = bob;
        h[2] = carol;
        uint256[] memory a = new uint256[](3);
        a[0] = 600e18;
        a[1] = 300e18;
        a[2] = 100e18;
        sh = new PropertyShares("Casa Palermo", "CASA1", reg, pid, h, a);
        dao.init(sh);
        vm.deal(tenant, 100 ether);
        vm.deal(buyer, 1000 ether);
        vm.roll(10);
        vm.warp(1_700_000_000);
    }

    function test_DeedMintedToDao() public view {
        assertEq(reg.ownerOf(pid), address(dao));
        assertEq(reg.tokenURI(pid), "ipfs://casa");
        (bytes32 h,, uint256 v) = reg.properties(pid);
        assertEq(h, keccak256("escritura.pdf"));
        assertEq(v, 300 ether);
    }

    function test_RentProRata() public {
        vm.prank(tenant);
        sh.depositRent{value: 10 ether}();
        assertApproxEqAbs(sh.withdrawableRentOf(alice), 6 ether, 1); // redondeo a favor del contrato
        assertApproxEqAbs(sh.withdrawableRentOf(bob), 3 ether, 1); // redondeo a favor del contrato
        vm.prank(carol);
        sh.withdrawRent();
        assertApproxEqAbs(carol.balance, 1 ether, 1); // redondeo a favor del contrato
        vm.prank(carol);
        vm.expectRevert(PropertyShares.NothingToWithdraw.selector);
        sh.withdrawRent();
    }

    function test_TransferDoesNotStealPastRent() public {
        vm.prank(tenant);
        sh.depositRent{value: 10 ether}();
        vm.prank(alice);
        sh.transfer(bob, 600e18);
        // alice conserva su renta pasada; bob no la gana
        assertApproxEqAbs(sh.withdrawableRentOf(alice), 6 ether, 1); // redondeo a favor del contrato
        assertApproxEqAbs(sh.withdrawableRentOf(bob), 3 ether, 1); // redondeo a favor del contrato
        vm.prank(tenant);
        sh.depositRent{value: 10 ether}();
        assertApproxEqAbs(sh.withdrawableRentOf(bob), 3 ether + 9 ether, 1); // redondeo a favor del contrato
        assertApproxEqAbs(sh.withdrawableRentOf(alice), 6 ether, 1); // redondeo a favor del contrato
    }

    function test_RevertWhen_TransferToNonKyc() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PropertyShares.NotVerified.selector, mallory));
        sh.transfer(mallory, 1e18);
    }

    function test_AutoDelegation() public view {
        assertEq(sh.getVotes(alice), 600e18);
        assertEq(sh.delegates(bob), bob);
    }

    function _passAndExecute(address target, uint256 value, bytes memory data) internal returns (uint256 id) {
        vm.prank(alice);
        id = dao.propose(target, value, data, "propuesta");
        vm.prank(alice);
        dao.vote(id, true);
        vm.prank(bob);
        dao.vote(id, false);
        vm.warp(block.timestamp + 5 days + 1);
        dao.queue(id);
        vm.warp(block.timestamp + 2 days);
        dao.execute(id);
    }

    function test_SaleFlow() public {
        vm.prank(buyer);
        uint256 offerId = dao.makeOffer{value: 330 ether}();
        _passAndExecute(address(dao), 0, abi.encodeCall(PropertyDAO.acceptOffer, (offerId)));
        assertEq(reg.ownerOf(pid), buyer);
        assertApproxEqAbs(sh.withdrawableRentOf(alice), 198 ether, 1); // redondeo a favor del contrato
        assertApproxEqAbs(sh.withdrawableRentOf(carol), 33 ether, 1); // redondeo a favor del contrato
        assertEq(dao.escrowed(), 0);
    }

    function test_PayExpenseButNotFromEscrow() public {
        address plumber = makeAddr("plumber");
        vm.deal(address(dao), 2 ether); // reserva operativa
        vm.prank(buyer);
        dao.makeOffer{value: 100 ether}();
        _passAndExecute(address(dao), 0, abi.encodeCall(PropertyDAO.pay, (payable(plumber), 1 ether)));
        assertEq(plumber.balance, 1 ether);
        // intentar gastar el escrow: la ejecución falla
        vm.prank(alice);
        uint256 id = dao.propose(address(dao), 0, abi.encodeCall(PropertyDAO.pay, (payable(plumber), 50 ether)), "x");
        vm.prank(alice);
        dao.vote(id, true);
        vm.warp(block.timestamp + 5 days + 1);
        dao.queue(id);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(PropertyDAO.CallFailed.selector);
        dao.execute(id);
    }

    function test_WithdrawOffer() public {
        vm.prank(buyer);
        uint256 id = dao.makeOffer{value: 10 ether}();
        vm.prank(alice);
        vm.expectRevert(PropertyDAO.NotBuyer.selector);
        dao.withdrawOffer(id);
        vm.prank(buyer);
        dao.withdrawOffer(id);
        assertEq(buyer.balance, 1000 ether);
    }

    function test_RevertWhen_AcceptOfferDirectly() public {
        vm.prank(buyer);
        dao.makeOffer{value: 10 ether}();
        vm.prank(alice);
        vm.expectRevert(PropertyDAO.OnlySelf.selector);
        dao.acceptOffer(0);
    }

    function test_RevertWhen_ExecuteBeforeTimelock() public {
        vm.prank(alice);
        uint256 id = dao.propose(address(dao), 0, "", "noop");
        vm.prank(alice);
        dao.vote(id, true);
        vm.warp(block.timestamp + 5 days + 1);
        dao.queue(id);
        vm.expectRevert(PropertyDAO.TooEarly.selector);
        dao.execute(id);
    }

    function test_QuorumNotReached() public {
        vm.prank(carol);
        uint256 id = dao.propose(address(dao), 0, "", "noop");
        vm.prank(carol);
        dao.vote(id, true); // 10% < 20%
        vm.warp(block.timestamp + 5 days + 1);
        vm.expectRevert(PropertyDAO.NotPassed.selector);
        dao.queue(id);
    }

    /// Votos comprados DESPUÉS de crear la propuesta no cuentan (snapshot).
    function test_SnapshotPreventsLateVoteBuying() public {
        vm.prank(carol);
        uint256 id = dao.propose(address(dao), 0, "", "noop");
        vm.roll(block.number + 1);
        vm.prank(alice);
        sh.transfer(carol, 600e18);
        vm.prank(carol);
        dao.vote(id, true);
        (uint256 f,,) = dao.getProposal(id);
        assertEq(f, 100e18);
    }

    function test_RevertWhen_BelowThreshold() public {
        vm.prank(registrar);
        reg.setVerified(mallory, true);
        vm.prank(carol);
        sh.transfer(mallory, 1e18); // 0,1%
        vm.roll(block.number + 1);
        vm.prank(mallory);
        vm.expectRevert(PropertyDAO.BelowThreshold.selector);
        dao.propose(address(dao), 0, "", "spam");
    }

    function testFuzz_RentConservation(uint96 rent, uint96 moved) public {
        rent = uint96(bound(rent, 1 gwei, 100 ether));
        moved = uint96(bound(moved, 0, 600e18));
        vm.prank(tenant);
        sh.depositRent{value: rent}();
        vm.prank(alice);
        sh.transfer(bob, moved);
        uint256 total = sh.withdrawableRentOf(alice) + sh.withdrawableRentOf(bob) + sh.withdrawableRentOf(carol);
        assertLe(total, rent);
        assertApproxEqAbs(total, rent, 3);
    }
}
