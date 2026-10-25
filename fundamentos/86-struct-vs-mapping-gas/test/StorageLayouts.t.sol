// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {PackedStruct, UnpackedStruct, SeparateMappings, StructArray} from "../src/StorageLayouts.sol";

/// @notice Mide gas de escritura/lectura por variante. Ejecutar con
///         `forge test -vv --gas-report` para ver la tabla completa.
contract StorageLayoutsTest is Test {
    PackedStruct packed;
    UnpackedStruct unpacked;
    SeparateMappings maps;
    StructArray arr;
    address u = makeAddr("user");

    function setUp() public {
        packed = new PackedStruct();
        unpacked = new UnpackedStruct();
        maps = new SeparateMappings();
        arr = new StructArray();
    }

    function test_GasPrimeraEscritura() public {
        uint256 g = gasleft();
        packed.set(u, 100, 1, true, 3);
        uint256 gP = g - gasleft();
        g = gasleft();
        unpacked.set(u, 100, 1, true, true);
        uint256 gU = g - gasleft();
        g = gasleft();
        maps.set(u, 100, 1, true, 3);
        uint256 gM = g - gasleft();
        console2.log("set packed struct   :", gP);
        console2.log("set unpacked struct :", gU);
        console2.log("set mappings sueltos:", gM);
        // 1 slot nuevo vs 4 slots nuevos: el empaquetado gana claramente.
        assertLt(gP, gU);
        assertLt(gP, gM);
    }

    function test_GasLectura() public {
        packed.set(u, 100, 1, true, 3);
        unpacked.set(u, 100, 1, true, true);
        maps.set(u, 100, 1, true, 3);
        uint256 g = gasleft();
        packed.get(u);
        uint256 gP = g - gasleft();
        g = gasleft();
        unpacked.get(u);
        uint256 gU = g - gasleft();
        g = gasleft();
        maps.get(u);
        uint256 gM = g - gasleft();
        console2.log("get packed  :", gP);
        console2.log("get unpacked:", gU);
        console2.log("get mappings:", gM);
        assertLt(gP, gU);
        assertLt(gP, gM);
    }

    function test_GasActualizarUnCampo() public {
        packed.set(u, 100, 1, true, 3);
        maps.set(u, 100, 1, true, 3);
        uint256 g = gasleft();
        packed.updateBalance(u, 200);
        uint256 gP = g - gasleft();
        g = gasleft();
        maps.updateBalance(u, 200);
        uint256 gM = g - gasleft();
        console2.log("update packed  :", gP);
        console2.log("update mapping :", gM);
        // Ambos tocan 1 slot; diferencia pequeña (enmascarado del empaquetado).
        assertApproxEqRel(gP, gM, 0.2e18);
    }

    function test_ArrayBusquedaLineal() public {
        for (uint160 i = 1; i <= 20; i++) arr.push(address(i), uint128(i), 0);
        uint256 g = gasleft();
        assertEq(arr.find(address(1)), 1);
        uint256 gPrimero = g - gasleft();
        g = gasleft();
        assertEq(arr.find(address(20)), 20);
        uint256 gUltimo = g - gasleft();
        console2.log("find primero:", gPrimero, "find ultimo:", gUltimo);
        assertGt(gUltimo, gPrimero * 5); // O(n): crece con la posición
    }

    function test_SlotsOcupados() public {
        packed.set(u, 1, 1, true, 1);
        // Ubicación del struct: keccak256(abi.encode(key, slotDelMapping=0)).
        bytes32 base = keccak256(abi.encode(u, uint256(0)));
        assertTrue(vm.load(address(packed), base) != bytes32(0));
        assertEq(vm.load(address(packed), bytes32(uint256(base) + 1)), bytes32(0), "packed usa 1 slot");
        unpacked.set(u, 1, 1, true, true);
        assertTrue(vm.load(address(unpacked), bytes32(uint256(base) + 3)) != bytes32(0), "unpacked usa 4 slots");
    }
}
