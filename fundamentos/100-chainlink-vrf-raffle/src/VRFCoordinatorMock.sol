// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVRFCoordinatorMinimal, VRFConsumerBaseMinimal} from "./VRFInterfaces.sol";

/// @title VRFCoordinatorMock — simula el Coordinator de Chainlink para tests
/// @notice Guarda las solicitudes y permite que el test las "cumpla" con el
///         número que quiera (o uno derivado del requestId). **Solo para
///         tests/redes locales**: no hay prueba criptográfica real.
contract VRFCoordinatorMock is IVRFCoordinatorMinimal {
    error UnknownRequest(uint256 id);

    event RandomWordsRequested(uint256 indexed requestId, address indexed consumer, uint32 numWords);
    event RandomWordsFulfilled(uint256 indexed requestId, bool success);

    struct Request {
        address consumer;
        uint32 numWords;
    }

    uint256 public nextRequestId = 1;
    mapping(uint256 => Request) public requests;

    function requestRandomWords(bytes32, uint256, uint16, uint32, uint32 numWords)
        external
        returns (uint256 requestId)
    {
        requestId = nextRequestId++;
        requests[requestId] = Request(msg.sender, numWords);
        emit RandomWordsRequested(requestId, msg.sender, numWords);
    }

    /// @notice Cumple con palabras derivadas de keccak(requestId, i).
    function fulfillRandomWords(uint256 requestId) external {
        Request memory r = requests[requestId];
        uint256[] memory words = new uint256[](r.numWords);
        for (uint256 i; i < r.numWords; ++i) {
            words[i] = uint256(keccak256(abi.encode(requestId, i)));
        }
        _fulfill(requestId, words);
    }

    /// @notice Cumple con palabras elegidas por el test (control total).
    function fulfillRandomWordsWithOverride(uint256 requestId, uint256[] memory words) external {
        _fulfill(requestId, words);
    }

    function _fulfill(uint256 requestId, uint256[] memory words) internal {
        Request memory r = requests[requestId];
        if (r.consumer == address(0)) revert UnknownRequest(requestId);
        delete requests[requestId];
        VRFConsumerBaseMinimal(r.consumer).rawFulfillRandomWords(requestId, words);
        emit RandomWordsFulfilled(requestId, true);
    }
}
