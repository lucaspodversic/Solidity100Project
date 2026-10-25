// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Vendor — máquina expendedora de tokens ERC20 por ETH
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #77
/// @notice Compra: el usuario envía ETH y recibe `tokensPerEth` tokens por ETH.
///         Venta: el usuario aprueba tokens al Vendor y recibe ETH a cambio.
/// @dev Puntos didácticos:
///   1. **SafeERC20**: algunos tokens (p. ej. USDT) no devuelven `bool` en
///      `transfer`; `safeTransfer` normaliza ese comportamiento y revierte
///      si la transferencia falla. Es la forma segura contrato-a-contrato.
///   2. **Flujo approve + transferFrom**: para vender, el contrato no puede
///      "tomar" tokens sin permiso; el usuario primero llama `approve`.
///   3. **ReentrancyGuard** + CEI al enviar ETH.
contract Vendor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Errores
    // ---------------------------------------------------------------------
    error ZeroAmount();
    error InsufficientTokenInventory(uint256 disponible, uint256 requerido);
    error InsufficientEthLiquidity(uint256 disponible, uint256 requerido);
    error EthTransferFailed();

    // ---------------------------------------------------------------------
    // Eventos
    // ---------------------------------------------------------------------
    event TokensBought(address indexed buyer, uint256 ethIn, uint256 tokensOut);
    event TokensSold(address indexed seller, uint256 tokensIn, uint256 ethOut);
    event EthWithdrawn(address indexed owner, uint256 amount);

    /// @notice Token que se vende.
    IERC20 public immutable token;
    /// @notice Tokens (en unidades de 18 decimales) entregados por cada 1 ETH.
    /// @dev Precio fijo: simple pero sin protección ante cambios de mercado.
    uint256 public constant tokensPerEth = 100;

    /// @param token_ Dirección del ERC20 a vender.
    constructor(IERC20 token_) Ownable(msg.sender) {
        token = token_;
    }

    /// @notice Comprar tokens enviando ETH.
    /// @return tokensOut Cantidad de tokens recibidos.
    function buyTokens() external payable nonReentrant returns (uint256 tokensOut) {
        if (msg.value == 0) revert ZeroAmount();
        // Ambos tienen 18 decimales, por eso basta multiplicar.
        tokensOut = msg.value * tokensPerEth;
        uint256 inv = token.balanceOf(address(this));
        if (inv < tokensOut) revert InsufficientTokenInventory(inv, tokensOut);
        emit TokensBought(msg.sender, msg.value, tokensOut);
        // Transferencia segura contrato -> usuario.
        token.safeTransfer(msg.sender, tokensOut);
    }

    /// @notice Vender tokens por ETH. Requiere `approve(vendor, amount)` previo.
    /// @param amount Tokens a vender.
    /// @return ethOut ETH recibido.
    function sellTokens(uint256 amount) external nonReentrant returns (uint256 ethOut) {
        if (amount == 0) revert ZeroAmount();
        // División entera: fracciones por debajo de 1 wei se pierden (redondeo
        // a favor del contrato, que es lo seguro).
        ethOut = amount / tokensPerEth;
        if (ethOut == 0) revert ZeroAmount();
        if (address(this).balance < ethOut) {
            revert InsufficientEthLiquidity(address(this).balance, ethOut);
        }
        // Primero traemos los tokens (si falla, revierte todo)...
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit TokensSold(msg.sender, amount, ethOut);
        // ...y recién después enviamos el ETH.
        (bool ok,) = msg.sender.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice El dueño retira el ETH acumulado por las ventas.
    function withdraw() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        emit EthWithdrawn(msg.sender, bal);
        (bool ok,) = msg.sender.call{value: bal}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice Permite al dueño fondear liquidez de ETH para recompras.
    receive() external payable {}
}
