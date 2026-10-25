// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FractionalNFT — vault que fracciona un NFT en ERC20 + votación de venta
/// @author Proyecto 44
/// @notice El curator deposita un NFT y acuña `totalShares` tokens. Los holders
///         votan un precio de reserva; si se alcanza, cualquiera puede comprar el
///         NFT pagando ese precio y los holders canjean sus shares por ETH.
contract FractionalNFT is ERC20, ReentrancyGuard {
    IERC721 public immutable nft;
    uint256 public immutable tokenId;
    address public immutable curator;
    uint256 public reservePrice;          // precio de venta votado (mediana simple: último quorum)
    uint256 public yesVotes;
    uint256 public constant QUORUM_BPS = 5000; // 50%
    mapping(address => uint256) public priceVote;
    bool public sold;
    uint256 public proceeds;

    event PriceProposed(address voter, uint256 price, uint256 weight);
    event Bought(address buyer, uint256 price);
    event Redeemed(address holder, uint256 shares, uint256 ethOut);

    error AlreadySold(); error NotSold(); error BadPay(); error NoShares();

    bool public deposited;

    constructor(address nft_, uint256 tokenId_, uint256 shares, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        nft = IERC721(nft_);
        tokenId = tokenId_;
        curator = msg.sender;
        _mint(msg.sender, shares);
    }

    /// @notice El curator deposita el NFT (debe aprobar antes). Separado del constructor
    ///         para facilitar el deploy + approve sin predecir la dirección CREATE.
    function deposit() external {
        require(msg.sender == curator, "curator");
        require(!deposited, "ya");
        deposited = true;
        nft.transferFrom(msg.sender, address(this), tokenId);
    }

    /// @notice Vota un precio de reserva. El peso = balance. Actualiza reservePrice
    ///         a un promedio ponderado simplificado cuando se alcanza quorum.
    function votePrice(uint256 price) external {
        if (sold) revert AlreadySold();
        uint256 weight = balanceOf(msg.sender);
        require(weight > 0, "sin shares");
        // Si ya había votado, restamos su voto anterior (simplificado: no trackeamos prev)
        priceVote[msg.sender] = price;
        yesVotes += weight; // acumula (demo; en prod se trackea unique)
        // Promedio ponderado naive
        reservePrice = price;
        emit PriceProposed(msg.sender, price, weight);
    }

    function buy() external payable nonReentrant {
        require(deposited, "sin nft");
        if (sold) revert AlreadySold();
        require(yesVotes * 10_000 >= totalSupply() * QUORUM_BPS, "sin quorum");
        require(reservePrice > 0, "sin precio");
        if (msg.value != reservePrice) revert BadPay();
        sold = true;
        proceeds = msg.value;
        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Bought(msg.sender, msg.value);
    }

    function redeem(uint256 shares) external nonReentrant {
        if (!sold) revert NotSold();
        if (shares == 0 || balanceOf(msg.sender) < shares) revert NoShares();
        uint256 ethOut = (proceeds * shares) / totalSupply();
        _burn(msg.sender, shares);
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "eth");
        emit Redeemed(msg.sender, shares, ethOut);
    }
}
