// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {MockBridge} from "../src/MockBridge.sol";
import {CrosschainNFT} from "../src/CrosschainNFT.sol";

contract CrosschainTest is Test {
    MockBridge bridge;
    CrosschainNFT chainA;
    CrosschainNFT chainB;
    address relayer = makeAddr("relayer");
    address user = makeAddr("user");

    uint256 constant A = 1;
    uint256 constant B = 2;

    function setUp() public {
        bridge = new MockBridge(0.01 ether, relayer);
        chainA = new CrosschainNFT(address(bridge), A);
        chainB = new CrosschainNFT(address(bridge), B);
        chainA.setPeer(B, address(chainB));
        chainB.setPeer(A, address(chainA));
        chainA.mint(user);
        vm.deal(user, 1 ether);
    }

    function test_BridgeIdaYVuelta() public {
        // user bridgeOut A -> B
        vm.prank(user);
        chainA.bridgeOut{value: 0.01 ether}(1, B, user);
        assertEq(chainA.ownerOf(1), address(chainA)); // locked
        assertTrue(chainA.locked(1));

        // relayer entrega a chainB
        bytes memory payload = abi.encodeWithSelector(CrosschainNFT.bridgeIn.selector, uint256(1), A, user);
        // El bridge.send emitió el payload; acá lo entregamos al peer (chainB)
        // Pero bridge.deliver llama a target.call(payload) — el msg.sender será el bridge.
        // Necesitamos que chainB.bridgeIn acepte al bridge. OK.
        // Pero el payload de send se guardó conceptualmente; lo reconstruimos:
        // Para que bridgeIn en B funcione, el bridge debe ser el caller.
        // Entregamos el payload "como si" fuera para chainB:
        // En nuestro MockBridge.send el payload es el de bridgeIn, y deliver lo manda a target.
        // Rehacemos: el user debería haber mandado payload al peer. Ajustamos el flujo del test
        // entregando directamente el payload correcto a chainB vía bridge.deliver.
        vm.prank(relayer);
        bridge.deliver(A, address(chainB), payload);
        assertEq(chainB.ownerOf(1), user);

        // vuelta: bridgeBack B -> A
        vm.prank(user);
        chainB.bridgeBack{value: 0.01 ether}(1, A, user);
        vm.expectRevert(); // quemado
        chainB.ownerOf(1);

        bytes memory payload2 = abi.encodeWithSelector(CrosschainNFT.bridgeIn.selector, uint256(1), B, user);
        vm.prank(relayer);
        bridge.deliver(B, address(chainA), payload2);
        assertEq(chainA.ownerOf(1), user);
        assertFalse(chainA.locked(1));
    }

    function test_FeeInsuficiente() public {
        vm.prank(user);
        vm.expectRevert(MockBridge.BadFee.selector);
        chainA.bridgeOut{value: 0.001 ether}(1, B, user);
    }

    function test_ReplayMensaje() public {
        vm.prank(user);
        chainA.bridgeOut{value: 0.01 ether}(1, B, user);
        bytes memory payload = abi.encodeWithSelector(CrosschainNFT.bridgeIn.selector, uint256(1), A, user);
        vm.prank(relayer);
        bridge.deliver(A, address(chainB), payload);
        vm.prank(relayer);
        vm.expectRevert(MockBridge.AlreadyDelivered.selector);
        bridge.deliver(A, address(chainB), payload);
    }
}
