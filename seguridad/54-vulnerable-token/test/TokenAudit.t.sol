// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {VulnerableToken, SafeToken} from "../src/VulnerableToken.sol";

contract TokenAuditTest is Test {
    VulnerableToken vul;
    SafeToken safe;
    address atk = makeAddr("atk");

    function setUp() public {
        vul = new VulnerableToken();
        safe = new SafeToken();
    }

    function test_H04_MintAbierto() public {
        vm.prank(atk); vul.mint(atk, 1_000_000e18);
        assertEq(vul.balanceOf(atk), 1_000_000e18);
        vm.prank(atk);
        vm.expectRevert(bytes("owner"));
        safe.mint(atk, 1);
    }

    function test_H03_BurnSinAllow() public {
        // transfer con fee: atk recibe 99
        vul.transfer(atk, 100e18);
        assertEq(vul.balanceOf(atk), 99e18);
        vul.burnFrom(atk, 99e18); // sin ser atk ni tener allowance
        assertEq(vul.balanceOf(atk), 0);

        safe.transfer(atk, 100e18);
        vm.expectRevert(bytes("allow"));
        safe.burnFrom(atk, 100e18);
    }

    function test_FeeOculto() public {
        address bob = makeAddr("bob");
        uint256 ownerAntes = vul.balanceOf(address(this));
        vul.transfer(bob, 100e18);
        assertEq(vul.balanceOf(bob), 99e18);
        // owner (this) perdió 100 pero recuperó 1 de fee
        assertEq(vul.balanceOf(address(this)), ownerAntes - 100e18 + 1e18);
    }
}
