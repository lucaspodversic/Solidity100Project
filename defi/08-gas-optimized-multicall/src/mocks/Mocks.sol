// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SelfMulticall} from "../SelfMulticall.sol";

/// @notice Contrato objetivo para los tests: un contador y un método que falla.
contract Target {
    uint256 public count;
    mapping(address => uint256) public received;

    function inc(uint256 by) external returns (uint256) {
        count += by;
        return count;
    }

    function fail() external pure {
        revert("fallo a proposito");
    }

    function pay() external payable {
        received[msg.sender] += msg.value;
    }

    function value() external view returns (uint256) {
        return count;
    }
}

/// @notice Banco que usa SelfMulticall correctamente (multicall no payable).
contract SafeBank is SelfMulticall {
    mapping(address => uint256) public balance;
    mapping(address => uint256) public points;

    function deposit() external payable {
        balance[msg.sender] += msg.value;
    }

    function addPoints(uint256 p) external {
        points[msg.sender] += p; // msg.sender se preserva con delegatecall
    }
}

/// @notice VERSIÓN VULNERABLE (sólo para el test): multicall payable + delegatecall.
contract VulnerableBank {
    mapping(address => uint256) public balance;

    function deposit() public payable {
        balance[msg.sender] += msg.value;
    }

    function multicall(bytes[] calldata data) external payable {
        for (uint256 i; i < data.length; i++) {
            (bool ok,) = address(this).delegatecall(data[i]);
            require(ok);
        }
    }
}
