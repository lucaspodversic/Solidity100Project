// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StableSwapPool — invariante StableSwap estilo Curve para N monedas (2 a 4)
/// @notice Pensado para activos que deberían valer lo mismo (USDC/USDT/DAI). El invariante
///         mezcla una suma constante (precio 1:1, sin slippage) con un producto constante
///         (robusto cuando el pool se desbalancea):
///
///           A·n^n·Σx_i + D = A·D·n^n + D^(n+1) / (n^n·Πx_i)
///
///         Con A grande el pool se comporta como Σx = D (casi sin slippage cerca del peg);
///         con A → 0 se comporta como Uniswap (Πx = cte). D es la "liquidez total" en unidades
///         de la moneda a 1:1.
/// @dev Los saldos se normalizan a 18 decimales con `rates`. D e y se resuelven con Newton
///      (máximo 255 iteraciones, convergencia a 1 wei). Comisión en unidades de 1e10 como Curve.
contract StableSwapPool is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Precisión de comisiones (1e10 = 100 %).
    uint256 public constant FEE_DENOMINATOR = 1e10;
    /// @notice Comisión máxima permitida: 1 %.
    uint256 public constant MAX_FEE = 1e8;
    uint256 public constant MAX_A = 1e6;
    /// @notice Cambio máximo de A por rampa (x10) y duración mínima (1 día).
    uint256 public constant MAX_A_CHANGE = 10;
    uint256 public constant MIN_RAMP_TIME = 1 days;

    /// @notice Cantidad de monedas.
    uint256 public immutable N;
    IERC20[] public coins;
    /// @notice Multiplicadores para llevar cada moneda a 18 decimales.
    uint256[] public rates;
    /// @notice Balances reales (en unidades nativas de cada token).
    uint256[] public balances;
    /// @notice Comisión de swap (ej. 4e6 = 0,04 %).
    uint256 public fee;

    // Rampa de A (cambio gradual para no permitir arbitraje instantáneo contra los LP).
    uint256 public initialA;
    uint256 public futureA;
    uint256 public initialATime;
    uint256 public futureATime;

    event TokenExchange(address indexed buyer, uint256 i, uint256 dx, uint256 j, uint256 dy);
    event AddLiquidity(address indexed provider, uint256[] amounts, uint256[] fees, uint256 invariant, uint256 lpMinted);
    event RemoveLiquidity(address indexed provider, uint256[] amounts, uint256 lpBurned);
    event RemoveLiquidityOne(address indexed provider, uint256 i, uint256 lpBurned, uint256 amount);
    event RampA(uint256 oldA, uint256 newA, uint256 initialTime, uint256 futureTime);

    error BadCoins();
    error BadIndex();
    error Slippage();
    error ZeroAmount();
    error InitialDepositNeedsAll();
    error DidNotConverge();
    error BadRamp();

    /// @param _coins Tokens del pool (2–4, todos con decimales <= 18).
    /// @param _A Coeficiente de amplificación inicial.
    /// @param _fee Comisión en 1e10.
    constructor(IERC20[] memory _coins, uint256 _A, uint256 _fee, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        if (_coins.length < 2 || _coins.length > 4) revert BadCoins();
        require(_A > 0 && _A <= MAX_A, "A");
        require(_fee <= MAX_FEE, "fee");
        N = _coins.length;
        for (uint256 i; i < N; i++) {
            uint8 d = IERC20Metadata(address(_coins[i])).decimals();
            require(d <= 18, "decimales");
            coins.push(_coins[i]);
            rates.push(10 ** (18 - d));
            balances.push(0);
        }
        initialA = _A;
        futureA = _A;
        fee = _fee;
    }

    // ------------------------------------------------------------------
    // Parámetro A con rampa
    // ------------------------------------------------------------------

    /// @notice A vigente, interpolado linealmente durante una rampa.
    function A() public view returns (uint256) {
        uint256 t1 = futureATime;
        uint256 a1 = futureA;
        if (block.timestamp >= t1) return a1;
        uint256 a0 = initialA;
        uint256 t0 = initialATime;
        if (a1 > a0) return a0 + ((a1 - a0) * (block.timestamp - t0)) / (t1 - t0);
        return a0 - ((a0 - a1) * (block.timestamp - t0)) / (t1 - t0);
    }

    /// @notice Inicia una rampa de A hacia `_futureA` que termina en `_futureTime`.
    /// @dev Cambiar A de golpe movería precios instantáneamente y regalaría valor a
    ///      arbitrajistas; por eso se limita a x10 y a un mínimo de 1 día.
    function rampA(uint256 _futureA, uint256 _futureTime) external onlyOwner {
        uint256 current = A();
        if (
            _futureTime < block.timestamp + MIN_RAMP_TIME || _futureA == 0 || _futureA > MAX_A
                || _futureA > current * MAX_A_CHANGE || _futureA * MAX_A_CHANGE < current
        ) revert BadRamp();
        initialA = current;
        futureA = _futureA;
        initialATime = block.timestamp;
        futureATime = _futureTime;
        emit RampA(current, _futureA, block.timestamp, _futureTime);
    }

    // ------------------------------------------------------------------
    // Matemática del invariante
    // ------------------------------------------------------------------

    /// @dev Balances normalizados a 18 decimales.
    function _xp(uint256[] memory bals) internal view returns (uint256[] memory xp) {
        xp = new uint256[](N);
        for (uint256 i; i < N; i++) {
            xp[i] = bals[i] * rates[i];
        }
    }

    function _balancesMem() internal view returns (uint256[] memory b) {
        b = new uint256[](N);
        for (uint256 i; i < N; i++) {
            b[i] = balances[i];
        }
    }

    /// @notice Resuelve D por Newton dado xp y amp.
    /// @dev f(D) = Ann·S + D − Ann·D − D^(n+1)/(n^n·Πx) = 0. Iteración de Curve:
    ///      D_{k+1} = (Ann·S + n·D_P)·D / ((Ann−1)·D + (n+1)·D_P), con D_P = D^(n+1)/(n^n·Πx).
    function getD(uint256[] memory xp, uint256 amp) public view returns (uint256) {
        uint256 s;
        for (uint256 i; i < N; i++) {
            s += xp[i];
        }
        if (s == 0) return 0;
        uint256 d = s;
        uint256 ann = amp * N ** N;
        for (uint256 it; it < 255; it++) {
            uint256 dP = d;
            for (uint256 i; i < N; i++) {
                dP = (dP * d) / (xp[i] * N); // si algún x_i = 0 revierte (división por cero): pool roto
            }
            uint256 prev = d;
            d = ((ann * s + dP * N) * d) / ((ann - 1) * d + (N + 1) * dP);
            if (d > prev ? d - prev <= 1 : prev - d <= 1) return d;
        }
        revert DidNotConverge();
    }

    /// @notice Nuevo saldo normalizado de la moneda j si la moneda i pasa a valer `x`.
    /// @dev Resuelve y² + (b − D)·y = c, con b = S' + D/Ann y c = D^(n+1)/(n^n·Πx'·Ann),
    ///      donde S' y Πx' excluyen a j. Newton: y = (y² + c) / (2y + b − D).
    function _getY(uint256 i, uint256 j, uint256 x, uint256[] memory xp, uint256 d) internal view returns (uint256) {
        if (i == j || i >= N || j >= N) revert BadIndex();
        uint256 ann = A() * N ** N;
        uint256 c = d;
        uint256 s;
        for (uint256 k; k < N; k++) {
            uint256 xk;
            if (k == i) xk = x;
            else if (k != j) xk = xp[k];
            else continue;
            s += xk;
            c = (c * d) / (xk * N);
        }
        return _solveY(c, s, d, ann);
    }

    /// @dev Igual que _getY pero para un D dado, excluyendo la moneda i (retiro de una moneda).
    function _getYD(uint256 i, uint256[] memory xp, uint256 d) internal view returns (uint256) {
        uint256 ann = A() * N ** N;
        uint256 c = d;
        uint256 s;
        for (uint256 k; k < N; k++) {
            if (k == i) continue;
            s += xp[k];
            c = (c * d) / (xp[k] * N);
        }
        return _solveY(c, s, d, ann);
    }

    /// @dev Iteración de Newton común a _getY y _getYD.
    function _solveY(uint256 c, uint256 s, uint256 d, uint256 ann) internal view returns (uint256 y) {
        c = (c * d) / (ann * N);
        uint256 b = s + d / ann;
        y = d;
        for (uint256 it; it < 255; it++) {
            uint256 prev = y;
            y = (y * y + c) / (2 * y + b - d);
            if (y > prev ? y - prev <= 1 : prev - y <= 1) return y;
        }
        revert DidNotConverge();
    }

    /// @notice Valor de 1 LP en unidades de la moneda a 1:1 (1e18). Solo sube con comisiones.
    function getVirtualPrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (getD(_xp(_balancesMem()), A()) * 1e18) / supply;
    }

    /// @notice Cotiza un swap de `dx` de la moneda i a la j (con comisión).
    function getDy(uint256 i, uint256 j, uint256 dx) public view returns (uint256 dy) {
        uint256[] memory xp = _xp(_balancesMem());
        uint256 d = getD(xp, A());
        uint256 x = xp[i] + dx * rates[i];
        uint256 y = _getY(i, j, x, xp, d);
        dy = xp[j] - y - 1; // -1 wei: redondeo a favor del pool
        dy -= (dy * fee) / FEE_DENOMINATOR;
        dy /= rates[j];
    }

    // ------------------------------------------------------------------
    // Operaciones
    // ------------------------------------------------------------------

    /// @notice Intercambia `dx` de la moneda `i` por al menos `minDy` de la moneda `j`.
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 minDy) external nonReentrant returns (uint256 dy) {
        if (dx == 0) revert ZeroAmount();
        dy = getDy(i, j, dx);
        if (dy < minDy) revert Slippage();
        balances[i] += dx;
        balances[j] -= dy; // la comisión queda en el pool => sube el virtual price
        coins[i].safeTransferFrom(msg.sender, address(this), dx);
        coins[j].safeTransfer(msg.sender, dy);
        emit TokenExchange(msg.sender, i, dx, j, dy);
    }

    /// @notice Deposita montos arbitrarios y recibe LP según el aumento de D.
    /// @dev Depósitos desbalanceados pagan una comisión proporcional a cuánto se alejan del
    ///      ratio ideal: es equivalente a un swap implícito y si no se cobrara sería una forma
    ///      de hacer swaps gratis (depositar un activo y retirar otro).
    function addLiquidity(uint256[] calldata amounts, uint256 minMint) external nonReentrant returns (uint256 minted) {
        require(amounts.length == N, "len");
        uint256 amp = A();
        uint256[] memory old = _balancesMem();
        uint256 supply = totalSupply();
        uint256 d0 = supply == 0 ? 0 : getD(_xp(old), amp);

        uint256[] memory newBal = new uint256[](N);
        for (uint256 i; i < N; i++) {
            if (supply == 0 && amounts[i] == 0) revert InitialDepositNeedsAll();
            newBal[i] = old[i] + amounts[i];
        }
        uint256 d1 = getD(_xp(newBal), amp);
        require(d1 > d0, "D no crece");

        uint256[] memory fees = new uint256[](N);
        if (supply == 0) {
            minted = d1;
        } else {
            // Comisión por desbalance: fee·n/(4(n−1)) sobre la desviación de cada moneda.
            uint256 baseFee = (fee * N) / (4 * (N - 1));
            uint256[] memory adj = new uint256[](N);
            for (uint256 i; i < N; i++) {
                uint256 ideal = (d1 * old[i]) / d0;
                uint256 diff = ideal > newBal[i] ? ideal - newBal[i] : newBal[i] - ideal;
                fees[i] = (baseFee * diff) / FEE_DENOMINATOR;
                adj[i] = newBal[i] - fees[i];
            }
            uint256 d2 = getD(_xp(adj), amp);
            minted = (supply * (d2 - d0)) / d0;
        }
        if (minted == 0 || minted < minMint) revert Slippage();
        for (uint256 i; i < N; i++) {
            balances[i] = newBal[i]; // las comisiones quedan en el pool
            if (amounts[i] > 0) coins[i].safeTransferFrom(msg.sender, address(this), amounts[i]);
        }
        _mint(msg.sender, minted);
        emit AddLiquidity(msg.sender, amounts, fees, d1, minted);
    }

    /// @notice Retiro proporcional (sin comisión; no cambia precios).
    function removeLiquidity(uint256 lp, uint256[] calldata minAmounts) external nonReentrant returns (uint256[] memory out) {
        require(minAmounts.length == N, "len");
        uint256 supply = totalSupply();
        out = new uint256[](N);
        _burn(msg.sender, lp); // primero quemamos (efectos antes de interacciones)
        for (uint256 i; i < N; i++) {
            out[i] = (balances[i] * lp) / supply;
            if (out[i] < minAmounts[i]) revert Slippage();
            balances[i] -= out[i];
            coins[i].safeTransfer(msg.sender, out[i]);
        }
        emit RemoveLiquidity(msg.sender, out, lp);
    }

    /// @notice Cotiza retirar `lp` en una sola moneda `i`.
    function calcWithdrawOneCoin(uint256 lp, uint256 i) public view returns (uint256 dy, uint256 dyFee) {
        if (i >= N) revert BadIndex();
        uint256[] memory xp = _xp(_balancesMem());
        uint256 d0 = getD(xp, A());
        uint256 d1 = d0 - (lp * d0) / totalSupply();
        uint256 newY = _getYD(i, xp, d1);
        uint256 baseFee = (fee * N) / (4 * (N - 1));
        uint256[] memory reduced = new uint256[](N);
        for (uint256 k; k < N; k++) {
            // Igual que en addLiquidity: la parte "desbalanceada" del retiro paga comisión.
            uint256 expected = k == i ? (xp[k] * d1) / d0 - newY : xp[k] - (xp[k] * d1) / d0;
            reduced[k] = xp[k] - (baseFee * expected) / FEE_DENOMINATOR;
        }
        uint256 dyNorm = reduced[i] - _getYD(i, reduced, d1) - 1;
        dy = dyNorm / rates[i];
        uint256 dyNoFee = (xp[i] - newY) / rates[i];
        dyFee = dyNoFee > dy ? dyNoFee - dy : 0;
    }

    /// @notice Retira `lp` íntegramente en la moneda `i`.
    function removeLiquidityOneCoin(uint256 lp, uint256 i, uint256 minAmount) external nonReentrant returns (uint256 dy) {
        (dy,) = calcWithdrawOneCoin(lp, i);
        if (dy < minAmount) revert Slippage();
        _burn(msg.sender, lp);
        balances[i] -= dy;
        coins[i].safeTransfer(msg.sender, dy);
        emit RemoveLiquidityOne(msg.sender, i, lp, dy);
    }

    /// @notice Cambia la comisión (≤ 1 %).
    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "fee");
        fee = _fee;
    }
}
