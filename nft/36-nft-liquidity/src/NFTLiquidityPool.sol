// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title NFTLiquidityPool — pool estilo AMM para una colección ERC721
/// @author Proyecto 36
/// @notice Estilo Sudoswap/NFTX simplificado: el pool tiene NFTs + reserva de ERC20.
///         Precio de compra/venta sigue una curva lineal: spot = base + slope * inventory.
///         Los LPs depositan NFTs y/o tokens y reciben shares proporcionalmente.
/// @dev No es un Uniswap de NFTs completo; es un bonding curve 1-collection para demo.
contract NFTLiquidityPool is ReentrancyGuard, Ownable {
    IERC721 public immutable nft;
    IERC20 public immutable token;

    uint256 public basePrice;   // precio mínimo en token units
    uint256 public slope;       // incremento por NFT en el pool
    uint256 public feeBps;      // fee de trading

    uint256[] private _inventory; // tokenIds en el pool
    mapping(uint256 => uint256) private _indexOf; // tokenId => index+1

    uint256 public totalShares;
    mapping(address => uint256) public shares;
    uint256 public reserve; // balance de token contado

    event Bought(address buyer, uint256 tokenId, uint256 price);
    event Sold(address seller, uint256 tokenId, uint256 price);
    event Deposit(address lp, uint256[] tokenIds, uint256 tokenAmount, uint256 mintedShares);
    event Withdraw(address lp, uint256 burnedShares);

    error Empty(); error BadPay(); error NoShares(); error TransferFail();

    constructor(address nft_, address token_, uint256 base_, uint256 slope_, uint256 feeBps_)
        Ownable(msg.sender)
    {
        nft = IERC721(nft_);
        token = IERC20(token_);
        basePrice = base_;
        slope = slope_;
        feeBps = feeBps_;
    }

    /// @notice Precio spot para COMPRAR el próximo NFT del pool.
    function buyPrice() public view returns (uint256) {
        // Más NFTs en inventario → más barato comprar (más oferta)
        uint256 n = _inventory.length;
        if (n == 0) return type(uint256).max;
        // precio = base + slope * (maxInventoryHint - n); simplificamos: base + slope * (10 - min(n,10))
        uint256 scarcity = n >= 10 ? 0 : (10 - n);
        uint256 raw = basePrice + slope * scarcity;
        return raw + (raw * feeBps) / 10_000;
    }

    /// @notice Precio spot para VENDER un NFT al pool.
    function sellPrice() public view returns (uint256) {
        uint256 n = _inventory.length;
        uint256 scarcity = n >= 10 ? 0 : (10 - n);
        uint256 raw = basePrice + slope * scarcity;
        // al vender, el pool paga menos (fee)
        uint256 fee = (raw * feeBps) / 10_000;
        return raw > fee ? raw - fee : 0;
    }

    /// @notice Compra el NFT en la cima del inventario.
    function buy() external nonReentrant returns (uint256 tokenId) {
        if (_inventory.length == 0) revert Empty();
        uint256 price = buyPrice();
        tokenId = _pop();
        // EFFECTS
        reserve += price;
        // INTERACTIONS
        if (!token.transferFrom(msg.sender, address(this), price)) revert TransferFail();
        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Bought(msg.sender, tokenId, price);
    }

    /// @notice Vende un NFT al pool al precio spot.
    function sell(uint256 tokenId) external nonReentrant {
        uint256 price = sellPrice();
        if (price > reserve) revert BadPay();
        // EFFECTS
        _push(tokenId);
        reserve -= price;
        // INTERACTIONS
        nft.transferFrom(msg.sender, address(this), tokenId);
        if (!token.transfer(msg.sender, price)) revert TransferFail();
        emit Sold(msg.sender, tokenId, price);
    }

    /// @notice LP deposita NFTs + tokens y recibe shares.
    function deposit(uint256[] calldata tokenIds, uint256 tokenAmount) external nonReentrant returns (uint256 minted) {
        for (uint i; i < tokenIds.length; ++i) {
            nft.transferFrom(msg.sender, address(this), tokenIds[i]);
            _push(tokenIds[i]);
        }
        if (tokenAmount > 0) {
            if (!token.transferFrom(msg.sender, address(this), tokenAmount)) revert TransferFail();
            reserve += tokenAmount;
        }
        // shares ~ tokenAmount + tokenIds.length * basePrice (valoración simple)
        uint256 value = tokenAmount + tokenIds.length * basePrice;
        if (totalShares == 0) minted = value;
        else minted = (value * totalShares) / (reserve + _inventory.length * basePrice - value + 1);
        // corrección: usamos value directo si pool vacío, si no proporcional a value
        if (totalShares == 0) minted = value == 0 ? 1 : value;
        else {
            uint256 poolValue = reserve + _inventory.length * basePrice;
            // poolValue ya incluye el depósito; restamos value para el denominador
            uint256 prev = poolValue > value ? poolValue - value : 1;
            minted = (value * totalShares) / prev;
        }
        shares[msg.sender] += minted;
        totalShares += minted;
        emit Deposit(msg.sender, tokenIds, tokenAmount, minted);
    }

    /// @notice Quema shares y retira proporción de tokens (NFTs se quedan; simplificación).
    /// @dev En un pool real se retiraría una mezcla; acá solo tokens para mantenerlo simple.
    function withdraw(uint256 shareAmount) external nonReentrant {
        if (shareAmount == 0 || shares[msg.sender] < shareAmount) revert NoShares();
        uint256 tokenOut = (reserve * shareAmount) / totalShares;
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        reserve -= tokenOut;
        if (!token.transfer(msg.sender, tokenOut)) revert TransferFail();
        emit Withdraw(msg.sender, shareAmount);
    }

    function inventoryLength() external view returns (uint256) { return _inventory.length; }

    function _push(uint256 tokenId) internal {
        _inventory.push(tokenId);
        _indexOf[tokenId] = _inventory.length; // 1-based
    }
    function _pop() internal returns (uint256 tokenId) {
        tokenId = _inventory[_inventory.length - 1];
        _inventory.pop();
        delete _indexOf[tokenId];
    }
}
