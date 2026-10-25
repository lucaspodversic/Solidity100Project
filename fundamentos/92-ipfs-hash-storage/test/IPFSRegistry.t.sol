// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IPFSRegistry} from "../src/IPFSRegistry.sol";

contract IPFSRegistryTest is Test {
    IPFSRegistry r;
    address alice = makeAddr("alice");
    string constant CID = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
    string constant CID2 = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

    function setUp() public {
        r = new IPFSRegistry();
    }

    function test_GuardarYLeer() public {
        vm.prank(alice);
        uint256 id = r.store(CID);
        (address owner,, string memory cid) = r.documents(id);
        assertEq(owner, alice);
        assertEq(cid, CID);
        assertEq(r.uri(id), string.concat("ipfs://", CID));
        assertEq(r.documentsOf(alice).length, 1);
    }

    function test_Actualizar() public {
        vm.startPrank(alice);
        uint256 id = r.store(CID);
        r.update(id, CID2);
        vm.stopPrank();
        (,, string memory cid) = r.documents(id);
        assertEq(cid, CID2);
    }

    function test_RevertNoDueno() public {
        vm.prank(alice);
        uint256 id = r.store(CID);
        vm.expectRevert(IPFSRegistry.NotDocumentOwner.selector);
        r.update(id, CID2);
    }

    function test_RevertVacio() public {
        vm.expectRevert(IPFSRegistry.EmptyCid.selector);
        r.store("");
    }

    function test_DigestCompacto() public {
        // Digest de ejemplo (sha256 del contenido); el CIDv0 es base58(0x1220||digest).
        bytes32 digest = sha256("hola ipfs");
        vm.prank(alice);
        r.storeDigest(digest);
        bytes memory mh = r.multihashOf(alice);
        assertEq(mh.length, 34);
        assertEq(uint8(mh[0]), 0x12);
        assertEq(uint8(mh[1]), 0x20);
    }

    function test_GasStringVsDigest() public {
        uint256 g = gasleft();
        r.store(CID);
        uint256 gStr = g - gasleft();
        g = gasleft();
        r.storeDigest(sha256("x"));
        uint256 gDig = g - gasleft();
        console2.log("gas CID string:", gStr, "gas digest:", gDig);
        assertLt(gDig, gStr);
    }
}
