// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title SimpleNFT — colección ERC721 completa con mint público, metadata y retiro de fondos
/// @author Proyecto 30 de "100 proyectos Solidity"
/// @notice Colección con suministro máximo, precio fijo de acuñación, límite por billetera,
///         URI base configurable y "revelado" (antes de revelar todos los tokens muestran una URI oculta).
/// @dev Hereda de ERC721Enumerable para poder listar tokens por dueño on-chain.
///      Sigue el patrón Checks-Effects-Interactions (CEI) en todas las funciones que mueven ETH.
contract SimpleNFT is ERC721Enumerable, Ownable {
    using Strings for uint256;

    // ---------------------------------------------------------------------
    // Constantes y estado
    // ---------------------------------------------------------------------

    /// @notice Cantidad máxima de tokens que podrán existir.
    uint256 public immutable maxSupply;
    /// @notice Precio en wei por cada token acuñado públicamente.
    uint256 public immutable mintPrice;
    /// @notice Máximo de tokens que una billetera puede acuñar por el mint público.
    uint256 public constant MAX_PER_WALLET = 5;

    /// @notice Próximo id a asignar (los ids arrancan en 1 para que el 0 signifique "inexistente").
    uint256 public nextId = 1;
    /// @notice Indica si el mint público está habilitado.
    bool public saleActive;
    /// @notice Indica si ya se revelaron los metadatos definitivos.
    bool public revealed;

    /// @dev URI base de los metadatos definitivos (ej: ipfs://CID/).
    string private _baseTokenURI;
    /// @dev URI única que se devuelve para todos los tokens antes del revelado.
    string private _hiddenURI;

    /// @notice Cuántos tokens acuñó cada billetera por el mint público.
    mapping(address => uint256) public mintedBy;

    // ---------------------------------------------------------------------
    // Eventos y errores
    // ---------------------------------------------------------------------

    /// @notice Se emite cuando el dueño cambia el estado de la venta.
    event SaleToggled(bool active);
    /// @notice Se emite al revelar la colección.
    event Revealed(string baseURI);
    /// @notice Se emite al retirar fondos.
    event Withdrawn(address indexed to, uint256 amount);

    error SaleInactive();
    error ZeroQuantity();
    error SoldOut();
    error WalletLimit();
    error WrongPayment(uint256 expected, uint256 sent);
    error TransferFailed();

    /// @param name_ Nombre de la colección.
    /// @param symbol_ Símbolo de la colección.
    /// @param maxSupply_ Suministro máximo.
    /// @param price_ Precio por token en wei.
    /// @param hiddenURI_ URI de "placeholder" usada antes del revelado.
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        uint256 price_,
        string memory hiddenURI_
    ) ERC721(name_, symbol_) Ownable(msg.sender) {
        maxSupply = maxSupply_;
        mintPrice = price_;
        _hiddenURI = hiddenURI_;
    }

    // ---------------------------------------------------------------------
    // Acuñación
    // ---------------------------------------------------------------------

    /// @notice Mint público pagando `mintPrice * quantity`.
    /// @param quantity Cantidad de tokens a acuñar.
    function mint(uint256 quantity) external payable {
        // CHECKS: venta activa, cantidad válida, suministro, límite y pago exacto.
        if (!saleActive) revert SaleInactive();
        if (quantity == 0) revert ZeroQuantity();
        if (nextId - 1 + quantity > maxSupply) revert SoldOut();
        if (mintedBy[msg.sender] + quantity > MAX_PER_WALLET) revert WalletLimit();
        uint256 cost = mintPrice * quantity;
        if (msg.value != cost) revert WrongPayment(cost, msg.value);

        // EFFECTS: registramos el contador antes de acuñar.
        mintedBy[msg.sender] += quantity;
        _mintBatch(msg.sender, quantity);
    }

    /// @notice Acuñación gratuita reservada al dueño (para el equipo, sorteos, etc.).
    /// @param to Destinatario.
    /// @param quantity Cantidad de tokens.
    function ownerMint(address to, uint256 quantity) external onlyOwner {
        if (quantity == 0) revert ZeroQuantity();
        if (nextId - 1 + quantity > maxSupply) revert SoldOut();
        _mintBatch(to, quantity);
    }

    /// @dev Acuña `quantity` tokens consecutivos. Usamos `_mint` y no `_safeMint` para que un
    ///      contrato receptor no pueda reentrar durante el bucle (no hay callback onERC721Received).
    function _mintBatch(address to, uint256 quantity) internal {
        uint256 id = nextId;
        // INTERACTIONS: ninguna externa, `_mint` no hace callbacks.
        for (uint256 i; i < quantity; ++i) {
            _mint(to, id + i);
        }
        nextId = id + quantity;
    }

    // ---------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------

    /// @notice Devuelve la URI de metadatos del token.
    /// @dev Antes del revelado devuelve la URI oculta; después, baseURI + id + ".json".
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId); // revierte si el token no existe
        if (!revealed) return _hiddenURI;
        return string.concat(_baseTokenURI, tokenId.toString(), ".json");
    }

    /// @notice Revela la colección fijando la URI base definitiva (solo una vez).
    function reveal(string calldata baseURI_) external onlyOwner {
        require(!revealed, "ya revelado");
        _baseTokenURI = baseURI_;
        revealed = true;
        emit Revealed(baseURI_);
    }

    /// @notice Activa o pausa la venta pública.
    function setSaleActive(bool active) external onlyOwner {
        saleActive = active;
        emit SaleToggled(active);
    }

    // ---------------------------------------------------------------------
    // Fondos
    // ---------------------------------------------------------------------

    /// @notice Retira todo el ETH recaudado a la dirección indicada.
    /// @dev Patrón pull: solo el dueño retira; usamos `call` y verificamos el resultado.
    function withdraw(address payable to) external onlyOwner {
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit Withdrawn(to, bal);
    }

    /// @notice Lista los ids que posee `owner` (gracias a ERC721Enumerable).
    function tokensOfOwner(address owner) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(owner);
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = tokenOfOwnerByIndex(owner, i);
    }
}
