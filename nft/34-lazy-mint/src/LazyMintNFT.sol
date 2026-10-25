// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LazyMintNFT — acuñación perezosa con firmas EIP-712
/// @author Proyecto 34
/// @notice El creador firma vouchers off-chain (tokenId, price, uri, buyer opcional).
///         El comprador paga on-chain y el token se acuña en ese momento (lazy mint).
/// @dev Dominio EIP-712: name="LazyMintNFT", version="1". Cada voucher se marca como usado.
contract LazyMintNFT is ERC721, EIP712, Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    /// @notice Voucher firmado por el minter autorizado.
    struct Voucher {
        uint256 tokenId;   // id a acuñar (debe estar libre)
        uint256 price;     // precio en wei
        address buyer;     // address(0) = cualquiera; si no, solo ese buyer
        string uri;        // metadata URI
    }

    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256("Voucher(uint256 tokenId,uint256 price,address buyer,string uri)");

    /// @notice Dirección autorizada a firmar vouchers (puede ser distinta del owner).
    address public minter;
    mapping(uint256 => string) private _uris;
    mapping(uint256 => bool) public voucherUsed;

    event Redeemed(uint256 indexed tokenId, address indexed buyer, uint256 price);
    event MinterUpdated(address minter);

    error BadSig();
    error Used();
    error WrongBuyer();
    error WrongPay(uint256 expected, uint256 sent);
    error PayFail();

    constructor(address minter_)
        ERC721("LazyMint", "LAZY")
        EIP712("LazyMintNFT", "1")
        Ownable(msg.sender)
    {
        minter = minter_;
    }

    /// @notice Canjea un voucher firmado: paga, acuña y guarda la URI.
    function redeem(Voucher calldata v, bytes calldata sig) external payable nonReentrant {
        if (voucherUsed[v.tokenId]) revert Used();
        if (v.buyer != address(0) && v.buyer != msg.sender) revert WrongBuyer();
        if (msg.value != v.price) revert WrongPay(v.price, msg.value);

        // Verificamos la firma EIP-712 del minter.
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(VOUCHER_TYPEHASH, v.tokenId, v.price, v.buyer, keccak256(bytes(v.uri))))
        );
        address signer = ECDSA.recover(digest, sig);
        if (signer != minter) revert BadSig();

        // EFFECTS
        voucherUsed[v.tokenId] = true;
        _uris[v.tokenId] = v.uri;
        _mint(msg.sender, v.tokenId);

        // INTERACTIONS: pago al owner (creador)
        if (v.price > 0) {
            (bool ok,) = owner().call{value: v.price}("");
            if (!ok) revert PayFail();
        }
        emit Redeemed(v.tokenId, msg.sender, v.price);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _uris[tokenId];
    }

    function setMinter(address m) external onlyOwner {
        minter = m;
        emit MinterUpdated(m);
    }

    /// @notice Expone el domain separator para tests / clientes off-chain.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
