// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SmartWallet} from "../src/SmartWallet.sol";

/// @dev Destino de prueba.
contract Shop {
    uint256 public sold;
    function buy() external payable { sold += msg.value; }
}

/// @dev Contrato "phishing": si la wallet usara tx.origin, este podría vaciarla.
contract Phisher {
    function trick(SmartWallet w) external {
        w.execute(address(this), address(w).balance, "");
    }
    receive() external payable {}
}

/// @title Tests de la SmartWallet
contract SmartWalletTest is Test {
    SmartWallet w;
    Shop shop;
    uint256 ownerPk = 0xA11CE;
    address owner;
    address op = makeAddr("operator");
    address g1 = makeAddr("g1");
    address g2 = makeAddr("g2");
    address g3 = makeAddr("g3");
    address newOwner = makeAddr("newOwner");

    function setUp() public {
        owner = vm.addr(ownerPk);
        address[] memory gs = new address[](3);
        gs[0] = g1; gs[1] = g2; gs[2] = g3;
        w = new SmartWallet(owner, gs, 2);
        shop = new Shop();
        vm.deal(address(w), 10 ether);
        vm.warp(10 days);
    }

    /// El owner ejecuta libremente.
    function test_OwnerExecute() public {
        vm.prank(owner);
        w.execute(address(shop), 1 ether, abi.encodeCall(Shop.buy, ()));
        assertEq(shop.sold(), 1 ether);
    }

    /// Un extraño no puede ejecutar.
    function test_RevertWhen_Stranger() public {
        vm.prank(makeAddr("x"));
        vm.expectRevert(SmartWallet.Unauthorized.selector);
        w.execute(address(shop), 1, "");
    }

    /// Anti-phishing: el owner llamando a un contrato malicioso no lo autoriza.
    function test_TxOriginPhishingFails() public {
        Phisher p = new Phisher();
        vm.prank(owner, owner); // msg.sender y tx.origin = owner
        vm.expectRevert(SmartWallet.Unauthorized.selector);
        p.trick(w);
    }

    /// Operador con límite diario y lista blanca.
    function test_OperatorLimits() public {
        vm.startPrank(owner);
        w.setOperator(op, true, 1 ether);
        w.setAllowedTarget(op, address(shop), true);
        vm.stopPrank();

        vm.prank(op);
        w.execute(address(shop), 0.6 ether, abi.encodeCall(Shop.buy, ()));
        assertEq(w.remainingToday(op), 0.4 ether);

        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(SmartWallet.DailyLimitExceeded.selector, 0.5 ether, 0.4 ether));
        w.execute(address(shop), 0.5 ether, abi.encodeCall(Shop.buy, ()));

        // al día siguiente se renueva
        vm.warp(block.timestamp + 1 days);
        vm.prank(op);
        w.execute(address(shop), 1 ether, abi.encodeCall(Shop.buy, ()));
        assertEq(shop.sold(), 1.6 ether);
    }

    /// El operador no puede llamar destinos fuera de la lista ni a la wallet.
    function test_OperatorCannotEscalate() public {
        vm.prank(owner);
        w.setOperator(op, true, 100 ether);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(SmartWallet.TargetNotAllowed.selector, address(w)));
        w.execute(address(w), 0, abi.encodeCall(SmartWallet.transferOwnership, (op)));
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(SmartWallet.TargetNotAllowed.selector, op));
        w.execute(op, 1 ether, "");
    }

    /// Lote atómico: si una falla, revierte todo.
    function test_BatchAtomic() public {
        SmartWallet.Call[] memory calls = new SmartWallet.Call[](2);
        calls[0] = SmartWallet.Call(address(shop), 1 ether, abi.encodeCall(Shop.buy, ()));
        calls[1] = SmartWallet.Call(address(shop), 0, hex"deadbeef"); // función inexistente
        vm.prank(owner);
        vm.expectRevert();
        w.executeBatch(calls);
        assertEq(shop.sold(), 0);

        calls[1] = SmartWallet.Call(address(shop), 2 ether, abi.encodeCall(Shop.buy, ()));
        vm.prank(owner);
        w.executeBatch(calls);
        assertEq(shop.sold(), 3 ether);
    }

    /// Recuperación social completa con retraso.
    function test_SocialRecovery() public {
        vm.prank(g1);
        w.proposeRecovery(newOwner);
        vm.prank(g2);
        w.approveRecovery();
        vm.expectRevert(SmartWallet.RecoveryNotReady.selector);
        w.executeRecovery();
        vm.warp(block.timestamp + 2 days);
        w.executeRecovery();
        assertEq(w.owner(), newOwner);
    }

    /// El owner puede cancelar una recuperación hostil.
    function test_OwnerCancelsRecovery() public {
        vm.prank(g1);
        w.proposeRecovery(newOwner);
        vm.prank(g2);
        w.approveRecovery();
        vm.prank(owner);
        w.cancelRecovery();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(SmartWallet.NoRecovery.selector);
        w.executeRecovery();
    }

    /// Las aprobaciones de una ronda anterior no cuentan para una nueva propuesta.
    function test_NewProposalResetsApprovals() public {
        vm.prank(g1);
        w.proposeRecovery(newOwner);
        vm.prank(g2);
        w.proposeRecovery(makeAddr("other")); // nueva ronda, 1 aprobación
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(SmartWallet.RecoveryNotReady.selector);
        w.executeRecovery();
        vm.prank(g2);
        vm.expectRevert(SmartWallet.AlreadyApproved.selector);
        w.approveRecovery();
    }

    /// EIP-1271: firma del owner válida; de otro, inválida.
    function test_EIP1271() public view {
        bytes32 h = keccak256("login a dApp");
        bytes32 wrapped = w.wrapHash(h);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, wrapped);
        assertEq(w.isValidSignature(h, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
        (v, r, s) = vm.sign(0xB0B, wrapped);
        assertEq(w.isValidSignature(h, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
        // una firma sobre el hash "crudo" (sin envolver) no sirve: anti-replay
        (v, r, s) = vm.sign(ownerPk, h);
        assertEq(w.isValidSignature(h, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    /// Fuzz: un operador nunca gasta más que su límite en un día.
    function testFuzz_OperatorNeverExceedsLimit(uint64 a, uint64 b) public {
        vm.startPrank(owner);
        w.setOperator(op, true, 1 ether);
        w.setAllowedTarget(op, address(shop), true);
        vm.stopPrank();
        vm.startPrank(op);
        try w.execute(address(shop), a, abi.encodeCall(Shop.buy, ())) {} catch {}
        try w.execute(address(shop), b, abi.encodeCall(Shop.buy, ())) {} catch {}
        vm.stopPrank();
        assertLe(shop.sold(), 1 ether);
    }
}
