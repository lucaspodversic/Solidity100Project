// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract MockERC20 is ERC20 {
    constructor() ERC20("USD Mock", "USDM") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}
