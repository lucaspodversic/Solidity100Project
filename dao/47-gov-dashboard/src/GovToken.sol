// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
contract GovToken is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Dash","DASH") ERC20Permit("Dash") { _mint(msg.sender, 1_000_000e18); }
    function _update(address f,address t,uint256 v) internal override(ERC20, ERC20Votes){ super._update(f,t,v); }
    function nonces(address o) public view override(ERC20Permit, Nonces) returns(uint256){ return super.nonces(o); }
}
