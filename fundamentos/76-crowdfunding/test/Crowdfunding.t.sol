// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Crowdfunding} from "../src/Crowdfunding.sol";

/// @notice Tests del crowdfunding: cubren cada transición de la máquina de estados.
contract CrowdfundingTest is Test {
    Crowdfunding cf;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // El creador despliega con meta 10 ETH y 7 días de plazo.
        vm.prank(creator);
        cf = new Crowdfunding(10 ether, 7 days);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_ConstructorInvalido() public {
        vm.expectRevert(Crowdfunding.InvalidParams.selector);
        new Crowdfunding(0, 1 days);
    }

    function test_AporteYEstadoActivo() public {
        vm.prank(alice);
        cf.contribute{value: 3 ether}();
        assertEq(cf.totalRaised(), 3 ether);
        assertEq(cf.contributions(alice), 3 ether);
        assertEq(uint8(cf.state()), uint8(Crowdfunding.State.Active));
    }

    function test_ReceiveCuentaComoAporte() public {
        vm.prank(bob);
        (bool ok,) = address(cf).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(cf.contributions(bob), 1 ether);
    }

    function test_RevertAporteCero() public {
        vm.expectRevert(Crowdfunding.ZeroContribution.selector);
        cf.contribute();
    }

    function test_ExitoYRetiro() public {
        vm.prank(alice);
        cf.contribute{value: 6 ether}();
        vm.prank(bob);
        cf.contribute{value: 5 ether}();
        vm.warp(block.timestamp + 7 days);
        assertEq(uint8(cf.state()), uint8(Crowdfunding.State.Successful));

        // Un tercero no puede retirar.
        vm.prank(alice);
        vm.expectRevert(Crowdfunding.NotCreator.selector);
        cf.withdraw();

        vm.prank(creator);
        cf.withdraw();
        assertEq(creator.balance, 11 ether);
        assertEq(uint8(cf.state()), uint8(Crowdfunding.State.Paid));
    }

    function test_NoSePuedeAportarTrasPlazo() public {
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Crowdfunding.InvalidState.selector, Crowdfunding.State.Failed, Crowdfunding.State.Active
            )
        );
        cf.contribute{value: 1 ether}();
    }

    function test_FalloYReembolso() public {
        vm.prank(alice);
        cf.contribute{value: 4 ether}();
        vm.warp(block.timestamp + 8 days);
        assertEq(uint8(cf.state()), uint8(Crowdfunding.State.Failed));

        uint256 antes = alice.balance;
        vm.prank(alice);
        cf.refund();
        assertEq(alice.balance, antes + 4 ether);

        // Doble reembolso no permitido.
        vm.prank(alice);
        vm.expectRevert(Crowdfunding.NothingToRefund.selector);
        cf.refund();
    }

    function test_NoReembolsoSiExito() public {
        vm.prank(alice);
        cf.contribute{value: 10 ether}();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert();
        cf.refund();
    }

    /// @notice Fuzz: la suma de aportes siempre coincide con totalRaised.
    function testFuzz_SumaAportes(uint96 a, uint96 b) public {
        vm.assume(a > 0 && b > 0);
        vm.deal(alice, a);
        vm.deal(bob, b);
        vm.prank(alice);
        cf.contribute{value: a}();
        vm.prank(bob);
        cf.contribute{value: b}();
        assertEq(cf.totalRaised(), uint256(a) + uint256(b));
        assertEq(address(cf).balance, cf.totalRaised());
    }
}
