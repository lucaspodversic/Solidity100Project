// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

/// @title Forwarder — forwarder de confianza (wrapper del de OpenZeppelin)
/// @notice Verifica firmas EIP-712 de `ForwardRequest`, gestiona nonces
///         (anti-replay) y deadlines, y reenvía la llamada al destino
///         agregando la dirección del firmante al final del calldata.
/// @dev Dominio EIP-712: name = "GaslessForwarder", version = "1".
contract Forwarder is ERC2771Forwarder {
    constructor() ERC2771Forwarder("GaslessForwarder") {}
}
