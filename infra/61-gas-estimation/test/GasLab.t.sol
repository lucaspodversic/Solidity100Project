// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import "../src/GasLab.sol";

/// @title Tests + mediciones de gas
/// @notice Correr con `forge test -vv` para ver la tabla de mediciones en los logs,
///         y con `forge test --gas-report` para el reporte por función.
/// @dev Medimos con `gasleft()` antes/después de cada llamada externa. Los números
///      incluyen el overhead de la llamada (CALL ~2.6k frío / 100 caliente).
contract GasLabTest is Test {
    ArrayStore arr;
    MappingStore map;
    PackedMappingStore packed;
    ParallelMappingsStore par;
    MicroOpts micro;

    uint256 constant N = 50; // cantidad de usuarios precargados

    function setUp() public {
        arr = new ArrayStore();
        map = new MappingStore();
        packed = new PackedMappingStore();
        par = new ParallelMappingsStore();
        micro = new MicroOpts();
        for (uint256 i = 1; i <= N; i++) {
            arr.add(i, i * 10);
            map.add(i, i * 10);
            packed.add(uint64(i), uint128(i * 10));
            par.add(i, i * 10);
        }
    }

    /// Correctitud: las 4 variantes devuelven lo mismo.
    function test_AllVariantsAgree() public view {
        for (uint256 i = 1; i <= N; i += 7) {
            uint256 expected = i * 10;
            assertEq(arr.find(i), expected);
            assertEq(map.find(i), expected);
            assertEq(packed.find(uint64(i)), expected);
            assertEq(par.find(i), expected);
        }
    }

    /// Inserción: el struct empaquetado gana (1 SSTORE vs 3).
    function test_GasInsert() public {
        uint256 id = N + 1;
        uint256 g;
        g = gasleft(); arr.add(id, 1); uint256 gArr = g - gasleft();
        g = gasleft(); map.add(id, 1); uint256 gMap = g - gasleft();
        g = gasleft(); packed.add(uint64(id), 1); uint256 gPacked = g - gasleft();
        g = gasleft(); par.add(id, 1); uint256 gPar = g - gasleft();
        console2.log("== INSERT ==");
        console2.log("array de structs     :", gArr);
        console2.log("mapping struct suelto:", gMap);
        console2.log("mapping empaquetado  :", gPacked);
        console2.log("mappings paralelos   :", gPar);
        assertLt(gPacked, gMap, "empaquetado debe ser mas barato");
        assertLt(gPacked, gArr);
    }

    /// Búsqueda del último elemento: el array es O(n), el mapping O(1).
    function test_GasLookupWorstCase() public view {
        uint256 g;
        g = gasleft(); arr.find(N); uint256 gArr = g - gasleft();
        g = gasleft(); map.find(N); uint256 gMap = g - gasleft();
        g = gasleft(); packed.find(uint64(N)); uint256 gPacked = g - gasleft();
        console2.log("== LOOKUP (ultimo de", N, ") ==");
        console2.log("array (O(n))   :", gArr);
        console2.log("mapping (O(1)) :", gMap);
        console2.log("packed (O(1))  :", gPacked);
        assertGt(gArr, gMap * 10, "el array con 50 elementos debe ser >10x mas caro");
    }

    /// Actualización de un campo.
    function test_GasUpdate() public {
        uint256 g;
        g = gasleft(); arr.update(N, 999); uint256 gArr = g - gasleft();
        g = gasleft(); map.update(N, 999); uint256 gMap = g - gasleft();
        g = gasleft(); packed.update(uint64(N), 999); uint256 gPacked = g - gasleft();
        g = gasleft(); par.update(N, 999); uint256 gPar = g - gasleft();
        console2.log("== UPDATE ==");
        console2.log("array    :", gArr);
        console2.log("mapping  :", gMap);
        console2.log("packed   :", gPacked);
        console2.log("paralelo :", gPar);
        assertGt(gArr, gMap);
        assertEq(map.find(N), 999);
    }

    /// Bucle ingenuo vs optimizado.
    function test_GasLoop() public {
        micro.seed(100);
        uint256 g = gasleft(); micro.sumNaive(); uint256 gNaive = g - gasleft();
        g = gasleft(); micro.sumOptimized(); uint256 gOpt = g - gasleft();
        console2.log("== LOOP 100 ==");
        console2.log("ingenuo    :", gNaive);
        console2.log("optimizado :", gOpt);
        assertLt(gOpt, gNaive);
        assertEq(micro.total(), 2 * 4950);
    }

    /// memory vs calldata.
    function test_GasMemoryVsCalldata() public view {
        uint256[] memory xs = new uint256[](64);
        for (uint256 i; i < 64; i++) xs[i] = i;
        uint256 g = gasleft(); micro.sumMemory(xs); uint256 gMem = g - gasleft();
        g = gasleft(); micro.sumCalldata(xs); uint256 gCd = g - gasleft();
        console2.log("== ARGS 64 uint256 ==");
        console2.log("memory   :", gMem);
        console2.log("calldata :", gCd);
        assertLt(gCd, gMem);
    }

    /// string revert vs custom error.
    function test_GasRevertStyles() public view {
        uint256 g = gasleft();
        try micro.revertString() {} catch {}
        uint256 gStr = g - gasleft();
        g = gasleft();
        try micro.revertCustom() {} catch {}
        uint256 gErr = g - gasleft();
        console2.log("== REVERT ==");
        console2.log("string       :", gStr);
        console2.log("custom error :", gErr);
        assertLt(gErr, gStr);
    }

    /// Fuzz: empaquetado conserva los valores (no hay truncamiento dentro de rango).
    function testFuzz_PackedRoundtrip(uint64 id, uint128 bal) public {
        packed.add(id, bal);
        assertEq(packed.find(id), bal);
    }
}
