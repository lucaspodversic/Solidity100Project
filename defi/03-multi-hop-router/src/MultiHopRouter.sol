// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SimplePool} from "./SimplePool.sol";

/// @title MultiHopRouter — halla y ejecuta la ruta óptima entre pools
/// @notice Mantiene un registro de pools (aristas de un grafo cuyos nodos son tokens) y busca,
///         mediante DFS acotado en profundidad, la secuencia de pools que maximiza la salida
///         para un monto de entrada dado. Luego ejecuta la ruta atómicamente con protección
///         de slippage sobre el resultado FINAL.
/// @dev La búsqueda es una función `view` (gratis vía eth_call). Para ejecución on-chain lo
///      habitual es calcular la ruta off-chain y pasarla a `swapAlongPath`; `swapBest` existe
///      por conveniencia pero su gas crece exponencialmente con `maxHops` y nº de pools.
///      Se limita `maxHops <= 4` y la cantidad de pools registrados a 32 para acotar el DoS.
contract MultiHopRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Máximo de saltos permitido en la búsqueda.
    uint256 public constant MAX_HOPS = 4;
    /// @notice Máximo de pools registrados (acota el costo de la búsqueda).
    uint256 public constant MAX_POOLS = 32;

    /// @notice Pools registrados (aristas del grafo).
    SimplePool[] public pools;
    mapping(address => bool) public isPool;

    /// @notice Resultado de la búsqueda.
    struct Route {
        SimplePool[] pools; // pools en orden
        address[] tokens; // tokens recorridos (len = pools + 1)
        uint256 amountOut; // salida esperada
    }

    error TooManyPools();
    error AlreadyRegistered();
    error NoRoute();
    error Slippage();
    error Expired();
    error BadPath();
    error UnknownPool();

    event PoolAdded(address pool);
    event RouteExecuted(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 hops);

    constructor() Ownable(msg.sender) {}

    /// @notice Registra un pool. Solo el owner (evita que alguien registre pools maliciosos
    ///         que devuelvan cotizaciones falsas o hagan DoS a la búsqueda).
    function addPool(SimplePool pool) external onlyOwner {
        if (pools.length >= MAX_POOLS) revert TooManyPools();
        if (isPool[address(pool)]) revert AlreadyRegistered();
        isPool[address(pool)] = true;
        pools.push(pool);
        emit PoolAdded(address(pool));
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    // ------------------------------------------------------------------
    // Búsqueda
    // ------------------------------------------------------------------

    /// @notice Busca la mejor ruta de `tokenIn` a `tokenOut` con hasta `maxHops` saltos.
    /// @dev DFS con backtracking. `used` evita reutilizar un pool en la misma ruta (reusar un
    ///      pool nunca mejora el resultado en x·y=k y podría generar ciclos infinitos).
    function findBestRoute(address tokenIn, address tokenOut, uint256 amountIn, uint256 maxHops)
        public
        view
        returns (Route memory best)
    {
        if (maxHops == 0 || maxHops > MAX_HOPS) maxHops = MAX_HOPS;
        uint256 n = pools.length;
        bool[] memory used = new bool[](n);
        uint256[] memory stack = new uint256[](maxHops); // índices de pools en la ruta actual
        best = _dfs(tokenIn, tokenOut, amountIn, 0, maxHops, used, stack, best);
    }

    /// @dev Paso recursivo del DFS. `depth` = saltos ya tomados.
    function _dfs(
        address current,
        address target,
        uint256 amount,
        uint256 depth,
        uint256 maxHops,
        bool[] memory used,
        uint256[] memory stack,
        Route memory best
    ) internal view returns (Route memory) {
        if (depth == maxHops) return best;
        uint256 n = pools.length;
        for (uint256 i; i < n; i++) {
            if (used[i] || !pools[i].hasToken(current)) continue;
            uint256 out = pools[i].getAmountOut(current, amount);
            if (out == 0) continue;
            address next = pools[i].otherToken(current);
            stack[depth] = i;
            if (next == target) {
                if (out > best.amountOut) best = _buildRoute(stack, depth + 1, current, out);
            } else {
                used[i] = true;
                best = _dfs(next, target, out, depth + 1, maxHops, used, stack, best);
                used[i] = false;
            }
        }
        return best;
    }

    /// @dev Construye la ruta a partir de la pila. Reconstruye los tokens desde el final.
    function _buildRoute(uint256[] memory stack, uint256 len, address lastIn, uint256 out)
        internal
        view
        returns (Route memory r)
    {
        r.pools = new SimplePool[](len);
        r.tokens = new address[](len + 1);
        r.amountOut = out;
        // Reconstruimos de atrás hacia adelante: el último pool entra con `lastIn`.
        address t = lastIn;
        r.tokens[len] = pools[stack[len - 1]].otherToken(lastIn);
        for (uint256 k = len; k > 0; k--) {
            r.pools[k - 1] = pools[stack[k - 1]];
            r.tokens[k - 1] = t;
            if (k > 1) t = pools[stack[k - 2]].otherToken(t);
        }
    }

    /// @notice Cotiza una ruta explícita.
    function quotePath(SimplePool[] calldata path, address tokenIn, uint256 amountIn) public view returns (uint256 out) {
        out = amountIn;
        address t = tokenIn;
        for (uint256 i; i < path.length; i++) {
            if (!isPool[address(path[i])]) revert UnknownPool();
            out = path[i].getAmountOut(t, out);
            t = path[i].otherToken(t);
        }
    }

    // ------------------------------------------------------------------
    // Ejecución
    // ------------------------------------------------------------------

    /// @notice Ejecuta una ruta explícita (normalmente calculada off-chain con findBestRoute).
    /// @param minOut Mínimo FINAL aceptable: los saltos intermedios usan minOut=0 porque solo
    ///        importa el resultado total (y revertir en el último salto revierte todo).
    function swapAlongPath(
        SimplePool[] calldata path,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 out) {
        if (block.timestamp > deadline) revert Expired();
        if (path.length == 0 || path.length > MAX_HOPS) revert BadPath();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        out = amountIn;
        address t = tokenIn;
        for (uint256 i; i < path.length; i++) {
            SimplePool p = path[i];
            if (!isPool[address(p)]) revert UnknownPool();
            IERC20(t).forceApprove(address(p), out);
            // El router recibe los intermedios; el último salto paga directo a `to`.
            address recipient = i == path.length - 1 ? to : address(this);
            address next = p.otherToken(t);
            out = p.swap(t, out, 0, recipient);
            t = next;
        }
        if (t != tokenOut) revert BadPath();
        if (out < minOut) revert Slippage();
        emit RouteExecuted(msg.sender, tokenIn, tokenOut, amountIn, out, path.length);
    }

    /// @notice Busca on-chain y ejecuta la mejor ruta (cómodo pero más caro en gas).
    function swapBest(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint256 maxHops, address to, uint256 deadline)
        external
        returns (uint256 out)
    {
        Route memory r = findBestRoute(tokenIn, tokenOut, amountIn, maxHops);
        if (r.amountOut == 0) revert NoRoute();
        out = this.swapAlongPathFor(r.pools, tokenIn, tokenOut, amountIn, minOut, to, deadline, msg.sender);
    }

    /// @notice Variante interna para `swapBest` que cobra al usuario original.
    /// @dev Solo puede llamarla el propio router (vía `this.`) para pasar memoria→calldata.
    function swapAlongPathFor(
        SimplePool[] calldata path,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline,
        address payer
    ) external returns (uint256 out) {
        require(msg.sender == address(this), "solo router");
        // Tomamos los fondos del pagador y luego reutilizamos la lógica con el router como dueño.
        IERC20(tokenIn).safeTransferFrom(payer, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(this), amountIn);
        out = this.swapAlongPath(path, tokenIn, tokenOut, amountIn, minOut, to, deadline);
    }
}
