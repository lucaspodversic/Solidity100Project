// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CPAMMFactory} from "./CPAMMFactory.sol";
import {CPAMMPair} from "./CPAMMPair.sol";

/// @title CPAMMRouter — Interfaz segura para usuarios finales
/// @notice Hace atómicas las operaciones "transferir + mint/swap/burn" del par y agrega las
///         protecciones que el par no tiene: deadline y montos mínimos (slippage).
/// @dev Sin estas protecciones un usuario sería víctima fácil de sandwich attacks:
///      un bot frontrunea, mueve el precio, el usuario compra caro y el bot vende después.
contract CPAMMRouter {
    using SafeERC20 for IERC20;

    CPAMMFactory public immutable factory;

    error Expired();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();
    error ExcessiveInputAmount();
    error InvalidPath();
    error InsufficientLiquidity();
    error InsufficientAmount();

    /// @dev Rechaza transacciones que quedaron colgadas en la mempool demasiado tiempo.
    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(CPAMMFactory _factory) {
        factory = _factory;
    }

    // ------------------------------------------------------------------
    // Matemática pura
    // ------------------------------------------------------------------

    /// @notice Dado `amountA` y las reservas, cuánto B equivale al precio spot (sin comisión).
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        return (amountA * reserveB) / reserveA;
    }

    /// @notice Salida máxima para una entrada dada, con comisión del 0,3%.
    /// @dev out = in*997*rOut / (rIn*1000 + in*997). Redondea hacia abajo (a favor del pool).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * reserveOut) / (reserveIn * 1000 + inWithFee);
    }

    /// @notice Entrada mínima para obtener `amountOut`. Redondea hacia arriba (+1).
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        if (amountOut == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) revert InsufficientLiquidity();
        return (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;
    }

    /// @dev Reservas ordenadas según (tokenA, tokenB).
    function getReserves(address tokenA, address tokenB) public view returns (uint256 rA, uint256 rB) {
        CPAMMPair pair = CPAMMPair(factory.getPair(tokenA, tokenB));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rA, rB) = tokenA == pair.token0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @notice Montos de salida encadenados a lo largo de `path`.
    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 rIn, uint256 rOut) = getReserves(path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], rIn, rOut);
        }
    }

    /// @notice Montos de entrada necesarios (recorriendo `path` de atrás hacia adelante).
    function getAmountsIn(uint256 amountOut, address[] memory path) public view returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 rIn, uint256 rOut) = getReserves(path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], rIn, rOut);
        }
    }

    // ------------------------------------------------------------------
    // Liquidez
    // ------------------------------------------------------------------

    /// @dev Calcula los montos óptimos a depositar respetando el ratio actual del pool.
    ///      Separado de `addLiquidity` para evitar "stack too deep".
    function _optimalAmounts(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        if (factory.getPair(tokenA, tokenB) == address(0)) factory.createPair(tokenA, tokenB);
        (uint256 rA, uint256 rB) = getReserves(tokenA, tokenB);
        if (rA == 0 && rB == 0) {
            // Primer depósito: el LP fija el precio inicial libremente.
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 bOptimal = quote(amountADesired, rA, rB);
            if (bOptimal <= amountBDesired) {
                if (bOptimal < amountBMin) revert InsufficientBAmount();
                (amountA, amountB) = (amountADesired, bOptimal);
            } else {
                uint256 aOptimal = quote(amountBDesired, rB, rA);
                if (aOptimal > amountADesired || aOptimal < amountAMin) revert InsufficientAAmount();
                (amountA, amountB) = (aOptimal, amountBDesired);
            }
        }
    }

    /// @notice Agrega liquidez en el ratio actual del pool (crea el par si no existe).
    /// @param amountADesired Máximo de A que el usuario está dispuesto a aportar (ídem B).
    /// @param amountAMin Mínimo aceptable de A (protección contra movimiento de precio; ídem B).
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _optimalAmounts(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        liquidity = _depositAndMint(tokenA, tokenB, amountA, amountB, to);
    }

    /// @dev Transfiere ambos tokens del usuario al par y acuña LP a `to`.
    function _depositAndMint(address tokenA, address tokenB, uint256 amountA, uint256 amountB, address to)
        internal
        returns (uint256)
    {
        address pair = factory.getPair(tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        return CPAMMPair(pair).mint(to);
    }

    /// @notice Retira liquidez quemando `liquidity` LP.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = factory.getPair(tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 a0, uint256 a1) = CPAMMPair(pair).burn(to);
        (amountA, amountB) = tokenA == CPAMMPair(pair).token0() ? (a0, a1) : (a1, a0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    // ------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------

    /// @dev Ejecuta los swaps sucesivos; cada par envía directamente al siguiente (ahorra gas).
    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            CPAMMPair pair = CPAMMPair(factory.getPair(input, output));
            uint256 out = amounts[i + 1];
            (uint256 o0, uint256 o1) = input == pair.token0() ? (uint256(0), out) : (out, uint256(0));
            address to = i < path.length - 2 ? factory.getPair(output, path[i + 2]) : _to;
            pair.swap(o0, o1, to, new bytes(0));
        }
    }

    /// @notice Vende exactamente `amountIn` y exige recibir al menos `amountOutMin`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, factory.getPair(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Compra exactamente `amountOut` gastando como máximo `amountInMax`.
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsIn(amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, factory.getPair(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }
}
