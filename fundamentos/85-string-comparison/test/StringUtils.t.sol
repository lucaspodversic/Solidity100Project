// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StringUtils, PasswordGame} from "../src/StringUtils.sol";

contract StringUtilsTest is Test {
    using StringUtils for string;
    PasswordGame game;

    function setUp() public {
        game = new PasswordGame(keccak256(bytes("solidity")));
    }

    function test_Iguales() public view {
        (bool a, bool b, bool c, bool d) = game.compare("hola", "hola");
        assertTrue(a && b && c && d);
    }

    function test_Distintos() public view {
        (bool a, bool b, bool c, bool d) = game.compare("hola", "chau");
        assertFalse(a || b || c || d);
    }

    function test_IgnoreCase() public view {
        (bool a,,, bool d) = game.compare("Hola", "hOLA");
        assertFalse(a);
        assertTrue(d);
    }

    function test_Adivinar() public {
        vm.expectRevert(PasswordGame.WrongAnswer.selector);
        game.guess("rust");
        game.guess("solidity");
        assertEq(game.winner(), address(this));
        vm.expectRevert(PasswordGame.AlreadySolved.selector);
        game.guess("solidity");
    }

    /// @notice Demostración de colisión con abi.encodePacked.
    function test_ColisionEncodePacked() public pure {
        bytes32 h1 = keccak256(abi.encodePacked("ab", "c"));
        bytes32 h2 = keccak256(abi.encodePacked("a", "bc"));
        assertEq(h1, h2, "encodePacked colisiona");
        assertTrue(keccak256(abi.encode("ab", "c")) != keccak256(abi.encode("a", "bc")));
    }

    /// @notice Gas: hash vs bucle con strings largos.
    function test_GasHashVsLoop() public view {
        string memory a = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor";
        string memory b = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor";
        uint256 g = gasleft();
        assertTrue(a.equal(b));
        uint256 gHash = g - gasleft();
        g = gasleft();
        assertTrue(a.equalLoop(b));
        uint256 gLoop = g - gasleft();
        console2.log("gas hash:", gHash, "gas loop:", gLoop);
        assertLt(gHash, gLoop);
    }

    function testFuzz_ConsistenciaMetodos(string memory a, string memory b) public pure {
        assertEq(a.equal(b), a.equalLoop(b));
        assertEq(a.equal(b), a.equalFast(b));
        assertTrue(a.equal(a));
    }
}
