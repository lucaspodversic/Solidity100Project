// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Timelock — cola de ejecución con delay obligatorio
/// @author Proyecto 43
/// @notice Solo el `proposer` puede encolar; cualquiera ejecuta tras `delay`.
///         El `admin` puede cancelar. Patrón clásico de Governor+Timelock.
contract Timelock {
    uint256 public immutable delay;
    address public proposer;
    address public admin;

    mapping(bytes32 => uint256) public etaOf; // id => timestamp de ejecución más temprano
    mapping(bytes32 => bool) public done;

    event Queued(bytes32 id, address target, uint256 value, bytes data, uint256 eta);
    event Executed(bytes32 id);
    event Cancelled(bytes32 id);

    error OnlyProposer(); error OnlyAdmin(); error Early(); error NotQueued(); error Done(); error Fail();

    constructor(uint256 delay_, address proposer_, address admin_) {
        delay = delay_;
        proposer = proposer_;
        admin = admin_;
    }

    function hashOp(address target, uint256 value, bytes calldata data, uint256 salt)
        public pure returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, salt));
    }

    function queue(address target, uint256 value, bytes calldata data, uint256 salt) external returns (bytes32 id) {
        if (msg.sender != proposer) revert OnlyProposer();
        id = hashOp(target, value, data, salt);
        if (etaOf[id] != 0) revert Done();
        uint256 eta = block.timestamp + delay;
        etaOf[id] = eta;
        emit Queued(id, target, value, data, eta);
    }

    function execute(address target, uint256 value, bytes calldata data, uint256 salt) external payable {
        bytes32 id = hashOp(target, value, data, salt);
        uint256 eta = etaOf[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert Early();
        if (done[id]) revert Done();
        done[id] = true;
        (bool ok,) = target.call{value: value}(data);
        if (!ok) revert Fail();
        emit Executed(id);
    }

    function cancel(address target, uint256 value, bytes calldata data, uint256 salt) external {
        if (msg.sender != admin) revert OnlyAdmin();
        bytes32 id = hashOp(target, value, data, salt);
        if (etaOf[id] == 0) revert NotQueued();
        delete etaOf[id];
        emit Cancelled(id);
    }

    receive() external payable {}
}
