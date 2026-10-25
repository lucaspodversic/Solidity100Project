// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
/// @title MockNFT — ERC721 mínimo para tests del marketplace
contract MockNFT is ERC721 {
    uint256 public nextId = 1;
    constructor() ERC721("Mock", "MOCK") {}
    /// @notice Acuña un token y lo entrega a `to`.
    function mint(address to) external returns (uint256 id) {
        id = nextId++;
        _mint(to, id);
    }
}
