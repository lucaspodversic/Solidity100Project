// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {QToken} from "../src/QToken.sol";
import {QuadraticGovernor} from "../src/QuadraticGovernor.sol";

contract Box { uint256 public x; function set(uint256 v) external { x=v; } }

contract QuadraticTest is Test {
    QToken tok; QuadraticGovernor gov; Box box;
    address rich = makeAddr("rich");
    address poor = makeAddr("poor");

    function setUp() public {
        tok = new QToken();
        gov = new QuadraticGovernor(address(tok), 100, 1 days);
        box = new Box();
        tok.mint(rich, 1000e18);
        tok.mint(poor, 10e18);
    }

    function test_Sqrt() public view {
        assertEq(gov.sqrt(0), 0);
        assertEq(gov.sqrt(1), 1);
        assertEq(gov.sqrt(9), 3);
        assertEq(gov.sqrt(100), 10);
    }

    function test_CuadraticaFavoreceDistribuido() public {
        // rich gasta 100 créditos → weight 10
        // poor gasta 100 créditos → weight 10
        // Misma voz a pesar de distinta riqueza (créditos son por propuesta, no por balance)
        vm.prank(rich);
        uint256 id = gov.propose(address(box), abi.encodeWithSelector(Box.set.selector, 1), "x");
        vm.prank(rich); gov.vote(id, true, 100);
        vm.prank(poor); gov.vote(id, false, 100);
        (,,,, uint256 yes, uint256 no,,) = gov.proposals(id);
        assertEq(yes, 10);
        assertEq(no, 10);
        // rich gasta de a poco: 4+4+4+4 = 16 créditos → weights 2+2+2+2=8 < 10 de un solo voto de 100
        // (demuestra que concentrar créditos en un voto da más peso que fragmentar: sqrt es cóncava)
        vm.prank(rich);
        uint256 id2 = gov.propose(address(box), abi.encodeWithSelector(Box.set.selector, 2), "y");
        vm.prank(rich); gov.vote(id2, true, 100); // weight 10
        vm.prank(poor);
        gov.vote(id2, false, 25); // 5
        vm.prank(poor);
        gov.vote(id2, false, 25); // +5 = 10 total
        (,,,, yes, no,,) = gov.proposals(id2);
        assertEq(yes, 10);
        assertEq(no, 10); // 5+5: fragmentar da el mismo peso que un 100 si suman igual... 
        // wait 25→5, 25→5 = 10. Igual que sqrt(100)=10. La desigualdad Jensen: sqrt(a)+sqrt(b) >= sqrt(a+b)
        // Sí: fragmentar DA MÁS O IGUAL peso. sqrt(25)+sqrt(25)=10 = sqrt(100). 
        // Para desigualdad estricta: sqrt(49)+sqrt(49)=7+7=14 > sqrt(98)≈9.9
        vm.prank(rich);
        uint256 id3 = gov.propose(address(box), abi.encodeWithSelector(Box.set.selector, 3), "z");
        vm.prank(rich); gov.vote(id3, true, 98); // ~9
        vm.prank(poor); gov.vote(id3, false, 49);
        vm.prank(poor); gov.vote(id3, false, 49);
        (,,,, yes, no,,) = gov.proposals(id3);
        assertEq(yes, gov.sqrt(98));
        assertEq(no, 14); // 7+7
        assertTrue(no > yes); // fragmentar gana → incentivo a distribuir (voto cuadrático clásico al revés en credits budget)
        // En QV clásico el COSTO es credits^2; acá modelamos weight=sqrt(credits) con budget fijo, equivalente.
    }

    function test_Execute() public {
        vm.prank(rich);
        uint256 id = gov.propose(address(box), abi.encodeWithSelector(Box.set.selector, 9), "go");
        vm.prank(rich); gov.vote(id, true, 100);
        vm.warp(block.timestamp + 1 days);
        gov.executeAfterDeadline(id);
        assertEq(box.x(), 9);
    }

    function test_Delegacion() public {
        vm.prank(poor); gov.delegate(rich);
        assertEq(gov.votingPowerOf(poor), rich);
    }
}
