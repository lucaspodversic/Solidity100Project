// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/// @title QToken — ERC20 simple para peso de votación cuadrática
contract QToken is ERC20, Ownable {
    constructor() ERC20("QGov","QGOV") Ownable(msg.sender) {}
    function mint(address to, uint256 a) external onlyOwner { _mint(to, a); }
}
