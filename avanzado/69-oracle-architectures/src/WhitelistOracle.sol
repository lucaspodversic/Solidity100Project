// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracle, Median} from "./IOracle.sol";

/// @title WhitelistOracle — Arquitectura 1: reporteros autorizados + mediana
/// @notice Un admin (idealmente multisig o DAO) mantiene una lista de reporteros
///         conocidos. Cada uno publica su valor; `latest()` devuelve la **mediana de los
///         reportes frescos**, exigiendo un quórum mínimo.
/// @dev Seguridad: la mediana tolera hasta ⌊(n−1)/2⌋ reporteros maliciosos. La confianza
///      está en el admin (elige a los reporteros) y en que la mayoría sea honesta.
///      Así funciona, a grandes rasgos, un feed de Chainlink (OCR agrega off-chain).
contract WhitelistOracle is IOracle, Ownable {
    struct Report {
        uint256 value;
        uint256 timestamp;
    }

    uint256 public constant MAX_REPORTERS = 31;
    uint256 public immutable maxAge;
    uint256 public quorum;
    address[] public reporters;
    mapping(address => bool) public isReporter;
    mapping(address => Report) public reports;

    event ReporterAdded(address r);
    event ReporterRemoved(address r);
    event Reported(address indexed r, uint256 value);

    error NotReporter();
    error NoQuorum();
    error TooMany();
    error BadQuorum();

    constructor(uint256 _maxAge, uint256 _quorum) Ownable(msg.sender) {
        maxAge = _maxAge;
        quorum = _quorum;
    }

    function addReporter(address r) external onlyOwner {
        if (reporters.length >= MAX_REPORTERS) revert TooMany();
        if (isReporter[r]) return;
        isReporter[r] = true;
        reporters.push(r);
        emit ReporterAdded(r);
    }

    function removeReporter(address r) external onlyOwner {
        if (!isReporter[r]) return;
        isReporter[r] = false;
        delete reports[r];
        for (uint256 i = 0; i < reporters.length; i++) {
            if (reporters[i] == r) {
                reporters[i] = reporters[reporters.length - 1];
                reporters.pop();
                break;
            }
        }
        emit ReporterRemoved(r);
    }

    function setQuorum(uint256 q) external onlyOwner {
        if (q == 0) revert BadQuorum();
        quorum = q;
    }

    /// @notice Un reportero publica (o actualiza) su valor.
    function report(uint256 value) external {
        if (!isReporter[msg.sender]) revert NotReporter();
        reports[msg.sender] = Report(value, block.timestamp);
        emit Reported(msg.sender, value);
    }

    /// @inheritdoc IOracle
    function latest() external view returns (uint256 value, uint256 updatedAt) {
        uint256 n = reporters.length;
        uint256[] memory vals = new uint256[](n);
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            Report memory r = reports[reporters[i]];
            if (r.timestamp != 0 && block.timestamp - r.timestamp <= maxAge) {
                vals[count++] = r.value;
                if (r.timestamp > updatedAt) updatedAt = r.timestamp;
            }
        }
        if (count < quorum || count == 0) revert NoQuorum();
        assembly {
            mstore(vals, count) // recorta el arreglo a los reportes frescos
        }
        value = Median.compute(vals);
    }
}
