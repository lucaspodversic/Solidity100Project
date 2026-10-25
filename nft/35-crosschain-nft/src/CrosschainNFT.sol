// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockBridge} from "./MockBridge.sol";

/// @title CrosschainNFT — NFT que viaja entre cadenas vía bridge (lock/mint)
/// @author Proyecto 35
/// @notice En la chain origen se "lockeá" (quema lógica) el token y se manda un mensaje;
///         en la destino se acuña un token espejo con el mismo id. El regreso quema el
///         espejo y desbloquea el original.
contract CrosschainNFT is ERC721, Ownable {
    MockBridge public immutable bridge;
    uint256 public immutable chainId;
    /// @notice Dirección hermana en la otra chain (seteada por el owner).
    mapping(uint256 => address) public peerOn; // dstChainId => peer
    mapping(uint256 => bool) public locked;    // token bloqueado en origen
    uint256 public nextId = 1;

    event BridgedOut(uint256 indexed tokenId, uint256 dstChainId, address to);
    event BridgedIn(uint256 indexed tokenId, uint256 srcChainId, address to);

    error NotPeer();
    error BadState();
    error OnlyBridge();

    constructor(address bridge_, uint256 chainId_)
        ERC721("XChainNFT", "XNFT") Ownable(msg.sender)
    {
        bridge = MockBridge(bridge_);
        chainId = chainId_;
    }

    function setPeer(uint256 dstChainId, address peer) external onlyOwner {
        peerOn[dstChainId] = peer;
    }

    function mint(address to) external onlyOwner returns (uint256 id) {
        id = nextId++;
        _mint(to, id);
    }

    /// @notice Bloquea el token local y pide al bridge acuñar el espejo en dst.
    function bridgeOut(uint256 tokenId, uint256 dstChainId, address to) external payable {
        if (ownerOf(tokenId) != msg.sender) revert BadState();
        if (peerOn[dstChainId] == address(0)) revert NotPeer();
        // EFFECTS: transferimos al contrato (lock) y marcamos.
        _transfer(msg.sender, address(this), tokenId);
        locked[tokenId] = true;
        // Payload: selector de bridgeIn + args
        bytes memory payload = abi.encodeWithSelector(
            this.bridgeIn.selector, tokenId, chainId, to
        );
        bridge.send{value: msg.value}(dstChainId, payload);
        // En un bridge real el payload iría al peer; acá el relayer lo entrega al peer.
        emit BridgedOut(tokenId, dstChainId, to);
    }

    /// @notice Llamado por el bridge al entregar el mensaje en la chain destino.
    /// @dev Solo el bridge puede llamar. Acuña (o desbloquea) el token al destinatario.
    function bridgeIn(uint256 tokenId, uint256 srcChainId, address to) external {
        if (msg.sender != address(bridge)) revert OnlyBridge();
        // Si el token nunca existió acá, lo acuñamos como espejo.
        // Si estaba locked (es el original volviendo), lo desbloqueamos.
        if (locked[tokenId]) {
            locked[tokenId] = false;
            _transfer(address(this), to, tokenId);
        } else if (_ownerOf(tokenId) == address(0)) {
            // espejo nuevo: acuñamos con el mismo id
            if (tokenId >= nextId) nextId = tokenId + 1;
            _mint(to, tokenId);
        } else {
            revert BadState();
        }
        emit BridgedIn(tokenId, srcChainId, to);
    }

    /// @notice Quema el espejo y pide desbloquear el original en la chain origen.
    function bridgeBack(uint256 tokenId, uint256 srcChainId, address to) external payable {
        if (ownerOf(tokenId) != msg.sender) revert BadState();
        if (peerOn[srcChainId] == address(0)) revert NotPeer();
        // Quemamos el espejo
        _burn(tokenId);
        bytes memory payload = abi.encodeWithSelector(
            this.bridgeIn.selector, tokenId, chainId, to
        );
        bridge.send{value: msg.value}(srcChainId, payload);
        emit BridgedOut(tokenId, srcChainId, to);
    }
}
