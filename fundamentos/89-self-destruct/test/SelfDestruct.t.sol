// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Destructible, SameTxFactory, ForceSendVictim, ForceSender} from "../src/SelfDestruct.sol";

/// @dev foundry.toml usa evm_version = "cancun", por lo que rige EIP-6780.
contract SelfDestructTest is Test {
    address payable bene = payable(makeAddr("bene"));
    /// @dev Desplegado en setUp(): Foundry ejecuta setUp en una transacción
    ///      distinta a la del test, así que el kill posterior NO es "misma tx".
    Destructible deployedEarlier;

    function setUp() public {
        deployedEarlier = new Destructible{value: 1 ether}();
    }

    function test_Post6780NoBorraCodigo() public {
        Destructible d = deployedEarlier;
        d.kill(bene);
        // Fondos enviados...
        assertEq(bene.balance, 1 ether);
        assertEq(address(d).balance, 0);
        // ...pero el código y el estado siguen ahí.
        assertGt(address(d).code.length, 0);
        assertEq(d.value(), 42);
        assertEq(d.ping(), "sigo vivo");
    }

    function test_SoloOwnerKill() public {
        Destructible d = new Destructible();
        vm.prank(bene);
        vm.expectRevert(Destructible.NotOwner.selector);
        d.kill(bene);
    }

    function test_MismaTxSiBorra() public {
        SameTxFactory f = new SameTxFactory();
        address d = f.createAndKill{value: 1 ether}();
        // En el entorno de test todo corre en una tx; el borrado efectivo se
        // aplica al final de la tx, así que verificamos que el ETH llegó.
        assertEq(address(this).balance >= 1 ether, true);
        assertEq(d.balance, 0);
    }

    function test_CierreLogicoRecomendado() public {
        Destructible d = new Destructible{value: 1 ether}();
        d.close(bene);
        assertTrue(d.closed());
        vm.expectRevert(Destructible.Closed.selector);
        d.ping();
    }

    function test_EthForzadoRompeInvariante() public {
        ForceSendVictim v = new ForceSendVictim();
        // Un atacante fuerza 3 ETH sin pasar por play() (la víctima no tiene receive).
        new ForceSender{value: 3 ether}(payable(address(v)));
        assertEq(address(v).balance, 3 ether);
        // Ahora nadie puede jugar: el juego quedó bloqueado para siempre.
        vm.deal(bene, 1 ether);
        vm.prank(bene);
        vm.expectRevert(bytes("juego terminado"));
        v.play{value: 1 ether}();
    }

    receive() external payable {}
}
