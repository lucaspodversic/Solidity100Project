// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SimplePool — pool x·y=k mínimo con comisión configurable
/// @notice Pool sencillo para que el router tenga "grafos" de liquidez sobre los cuales rutear.
///         Cada pool puede tener una comisión distinta (en bps) para que la ruta óptima no sea
///         trivial: a veces conviene más saltos con comisión baja y mucha liquidez.
/// @dev Liquidez sin tokens LP (un único dueño) para mantener el foco en el ruteo.
contract SimplePool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    /// @notice Comisión en puntos básicos (30 = 0,30 %).
    uint256 public immutable feeBps;
    address public immutable owner;

    uint256 public reserveA;
    uint256 public reserveB;

    error NotOwner();
    error BadToken();
    error Slippage();
    error ZeroAmount();

    event Swap(address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to);

    constructor(IERC20 _a, IERC20 _b, uint256 _feeBps) {
        require(_feeBps < 10_000, "fee");
        tokenA = _a;
        tokenB = _b;
        feeBps = _feeBps;
        owner = msg.sender;
    }

    /// @notice El dueño agrega liquidez (cualquier ratio; fija el precio la primera vez).
    function addLiquidity(uint256 a, uint256 b) external {
        if (msg.sender != owner) revert NotOwner();
        tokenA.safeTransferFrom(msg.sender, address(this), a);
        tokenB.safeTransferFrom(msg.sender, address(this), b);
        reserveA += a;
        reserveB += b;
    }

    /// @notice Cotiza la salida de vender `amountIn` de `tokenIn`.
    /// @dev out = in·(1−fee)·rOut / (rIn + in·(1−fee)).
    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        (uint256 rIn, uint256 rOut) = _reserves(tokenIn);
        if (amountIn == 0 || rIn == 0 || rOut == 0) return 0;
        uint256 inFee = amountIn * (10_000 - feeBps);
        return (inFee * rOut) / (rIn * 10_000 + inFee);
    }

    /// @notice Devuelve el otro token del par.
    function otherToken(address t) external view returns (address) {
        if (t == address(tokenA)) return address(tokenB);
        if (t == address(tokenB)) return address(tokenA);
        revert BadToken();
    }

    /// @notice ¿El pool contiene el token `t`?
    function hasToken(address t) external view returns (bool) {
        return t == address(tokenA) || t == address(tokenB);
    }

    /// @notice Swap: el llamador ya debe haber transferido `amountIn` al pool (patrón V2),
    ///         o lo aprueba y el pool lo toma. Aquí usamos el patrón "pull" con transferFrom.
    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address to) external nonReentrant returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        out = getAmountOut(tokenIn, amountIn);
        if (out < minOut || out == 0) revert Slippage();
        bool aIn = tokenIn == address(tokenA);
        if (!aIn && tokenIn != address(tokenB)) revert BadToken();
        // Efectos antes de interacciones (checks-effects-interactions).
        if (aIn) {
            reserveA += amountIn;
            reserveB -= out;
        } else {
            reserveB += amountIn;
            reserveA -= out;
        }
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        (aIn ? tokenB : tokenA).safeTransfer(to, out);
        emit Swap(tokenIn, amountIn, out, to);
    }

    function _reserves(address tokenIn) internal view returns (uint256, uint256) {
        if (tokenIn == address(tokenA)) return (reserveA, reserveB);
        if (tokenIn == address(tokenB)) return (reserveB, reserveA);
        revert BadToken();
    }
}
