// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RebaseToken} from "./RebaseToken.sol";
import {MockRouter, IMessageReceiver} from "./MockRouter.sol";

/// @title TokenPool — Puente burn & mint de RebaseToken que **preserva la tasa del usuario**
/// @notice Origen: cristaliza el interés, quema y envía `(receptor, monto, tasa)`.
///         Destino: verifica router, cadena y pool remoto, y acuña con esa tasa.
contract TokenPool is Ownable, IMessageReceiver {
    RebaseToken public immutable token;
    MockRouter public immutable router;
    uint64 public immutable chainSelector;

    /// @notice cadena remota => pool autorizado en esa cadena
    mapping(uint64 => address) public remotePool;
    mapping(bytes32 => bool) public processed;

    event Bridged(bytes32 indexed id, address indexed from, address to, uint64 destChain, uint256 amount, uint256 rate);
    event Received(bytes32 indexed id, address indexed to, uint64 sourceChain, uint256 amount, uint256 rate);

    error OnlyRouter();
    error UnknownRemote();
    error Replay();
    error ZeroAmount();

    constructor(RebaseToken t, MockRouter r, uint64 selector) Ownable(msg.sender) {
        token = t;
        router = r;
        chainSelector = selector;
    }

    function setRemotePool(uint64 chain, address pool) external onlyOwner {
        remotePool[chain] = pool;
    }

    /// @notice Envía `amount` (o todo con max) a `to` en `destChain`.
    function bridge(uint64 destChain, address to, uint256 amount) external returns (bytes32 id) {
        address remote = remotePool[destChain];
        if (remote == address(0)) revert UnknownRemote();
        // tasa ANTES de quemar (si se quema todo, el mapping sigue igual, pero la leemos antes por claridad)
        uint256 rate = token.userRate(msg.sender);
        uint256 burned = token.burn(msg.sender, amount);
        if (burned == 0) revert ZeroAmount();
        id = router.send(chainSelector, destChain, remote, abi.encode(to, burned, rate));
        emit Bridged(id, msg.sender, to, destChain, burned, rate);
    }

    /// @inheritdoc IMessageReceiver
    function receiveMessage(bytes32 id, uint64 sourceChain, address sourceSender, bytes calldata payload) external {
        if (msg.sender != address(router)) revert OnlyRouter();
        if (remotePool[sourceChain] == address(0) || remotePool[sourceChain] != sourceSender) revert UnknownRemote();
        if (processed[id]) revert Replay();
        processed[id] = true;
        (address to, uint256 amount, uint256 rate) = abi.decode(payload, (address, uint256, uint256));
        token.mint(to, amount, rate);
        emit Received(id, to, sourceChain, amount, rate);
    }
}
