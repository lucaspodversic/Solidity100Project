// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Callback opcional para "flash swaps": el par entrega tokens ANTES de cobrar.
interface ICPAMMCallee {
    /// @param sender Quien llamó a `swap`.
    /// @param amount0 Cantidad de token0 entregada por adelantado.
    /// @param amount1 Cantidad de token1 entregada por adelantado.
    /// @param data Datos arbitrarios reenviados desde `swap`.
    function cpammCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

/// @title CPAMMPair — Par de producto constante (x * y = k) estilo Uniswap V2
/// @author Lote DeFi — solidity-100
/// @notice Cada par custodia dos tokens y emite tokens LP (ERC-20) que representan
///         la participación proporcional de cada proveedor de liquidez en las reservas.
/// @dev Diseño "low-level" igual que Uniswap V2: el usuario (o el Router) TRANSFIERE
///      primero los tokens al par y después llama a `mint`/`swap`; el par calcula lo
///      recibido como `balance - reserva`. Esto permite composición y flash swaps,
///      pero exige que los usuarios finales usen el Router (que hace todo atómico).
///
///      Invariante económico: después de cada swap,
///         (balance0 * 1000 - in0 * 3) * (balance1 * 1000 - in1 * 3) >= reserve0 * reserve1 * 1000^2
///      es decir, k NO puede bajar (descontada la comisión del 0,3% que queda para los LP).
contract CPAMMPair is ERC20 {
    using SafeERC20 for IERC20;

    /// @notice Liquidez mínima que se "quema" en el primer depósito (a address(0xdead)).
    /// @dev Evita que el precio por share LP sea manipulable a valores absurdos
    ///      (ataque de inflación del primer depositante) y que totalSupply llegue a 0.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Comisión de swap en puntos básicos sobre 1000 (3 = 0,3%).
    uint256 public constant FEE_NUM = 3;
    uint256 public constant FEE_DEN = 1000;

    /// @notice Fábrica que creó el par (única autorizada a inicializarlo).
    address public immutable factory;
    /// @notice Tokens del par, ordenados por dirección (token0 < token1).
    address public token0;
    address public token1;

    /// @dev Reservas registradas (pueden diferir del balance real hasta `sync`).
    uint112 private reserve0;
    uint112 private reserve1;
    /// @dev Timestamp del último update (módulo 2^32), usado para el oráculo TWAP.
    uint32 private blockTimestampLast;

    /// @notice Acumuladores de precio (UQ112x112 * segundos) para TWAP externos.
    /// @dev precio0 = reserve1/reserve0. Se permiten overflows (aritmética modular deseada).
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    /// @dev Cerrojo anti-reentrancia (1 = libre, 2 = tomado).
    uint256 private unlocked = 1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    error Locked();
    error Forbidden();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
    error KInvariant();
    error Overflow();

    /// @dev Modificador de exclusión mutua: bloquea reentradas en mint/burn/swap/skim/sync.
    modifier lock() {
        if (unlocked != 1) revert Locked();
        unlocked = 2;
        _;
        unlocked = 1;
    }

    constructor() ERC20("CPAMM LP", "CPLP") {
        factory = msg.sender;
    }

    /// @notice Inicializa los tokens del par. Solo la fábrica, una única vez.
    function initialize(address _token0, address _token1) external {
        if (msg.sender != factory || token0 != address(0)) revert Forbidden();
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice Devuelve las reservas y el timestamp del último update.
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @dev Actualiza reservas y, en el primer update de cada bloque, los acumuladores TWAP.
    ///      Usamos los valores de reserva ANTERIORES al swap: así un atacante no puede mover
    ///      el acumulador dentro del mismo bloque (tendría que sostener el precio manipulado
    ///      durante bloques enteros, pagando el costo de arbitraje).
    function _update(uint256 balance0, uint256 balance1, uint112 _r0, uint112 _r1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        uint32 ts = uint32(block.timestamp % 2 ** 32);
        unchecked {
            uint32 elapsed = ts - blockTimestampLast; // overflow intencional (modular)
            if (elapsed > 0 && _r0 != 0 && _r1 != 0) {
                // precio en punto fijo Q112: (r1 << 112) / r0
                price0CumulativeLast += ((uint256(_r1) << 112) / _r0) * elapsed;
                price1CumulativeLast += ((uint256(_r0) << 112) / _r1) * elapsed;
            }
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = ts;
        emit Sync(reserve0, reserve1);
    }

    /// @notice Acuña LP a `to` según los tokens transferidos previamente al par.
    /// @dev Primer depósito: liquidity = sqrt(a0*a1) - MINIMUM_LIQUIDITY (media geométrica,
    ///      independiente del ratio inicial). Depósitos siguientes: el mínimo de las dos
    ///      proporciones, así quien deposita desbalanceado "regala" el excedente a los LP
    ///      existentes (incentivo a depositar en el ratio actual).
    /// @return liquidity Tokens LP acuñados.
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _r0, uint112 _r1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _r0;
        uint256 amount1 = balance1 - _r1;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY; // revierte si es < 1000
            // Se quema para siempre: nadie puede retirar estas shares.
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min((amount0 * _totalSupply) / _r0, (amount1 * _totalSupply) / _r1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1, _r0, _r1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Quema los LP que se hayan transferido al par y devuelve los tokens subyacentes.
    /// @dev Se reparte proporcional al BALANCE (no a la reserva) para incluir comisiones/donaciones.
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 _r0, uint112 _r1,) = getReserves();
        address _t0 = token0;
        address _t1 = token1;
        uint256 balance0 = IERC20(_t0).balanceOf(address(this));
        uint256 balance1 = IERC20(_t1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 _totalSupply = totalSupply();
        // Redondeo hacia abajo: favorece al pool (y a los LP que quedan), nunca al que retira.
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        _burn(address(this), liquidity);
        IERC20(_t0).safeTransfer(to, amount0);
        IERC20(_t1).safeTransfer(to, amount1);

        balance0 = IERC20(_t0).balanceOf(address(this));
        balance1 = IERC20(_t1).balanceOf(address(this));
        _update(balance0, balance1, _r0, _r1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Swap de bajo nivel. Envía `amount0Out`/`amount1Out` a `to` y luego verifica k.
    /// @dev Si `data` no está vacío, llama al callback (flash swap): el receptor puede usar
    ///      los tokens y devolver (más la comisión) dentro de la misma transacción.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 _r0, uint112 _r1,) = getReserves();
        if (amount0Out >= _r0 || amount1Out >= _r1) revert InsufficientLiquidity();

        uint256 balance0;
        uint256 balance1;
        {
            // Bloque para evitar "stack too deep".
            address _t0 = token0;
            address _t1 = token1;
            if (to == _t0 || to == _t1) revert InvalidTo();
            // Transferencia optimista: primero entregamos, después cobramos.
            if (amount0Out > 0) IERC20(_t0).safeTransfer(to, amount0Out);
            if (amount1Out > 0) IERC20(_t1).safeTransfer(to, amount1Out);
            if (data.length > 0) ICPAMMCallee(to).cpammCall(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_t0).balanceOf(address(this));
            balance1 = IERC20(_t1).balanceOf(address(this));
        }
        uint256 amount0In = balance0 > _r0 - amount0Out ? balance0 - (_r0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _r1 - amount1Out ? balance1 - (_r1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();
        {
            // Balances "ajustados" descontando la comisión sobre lo que ENTRÓ.
            uint256 b0Adj = balance0 * FEE_DEN - amount0In * FEE_NUM;
            uint256 b1Adj = balance1 * FEE_DEN - amount1In * FEE_NUM;
            if (b0Adj * b1Adj < uint256(_r0) * uint256(_r1) * (FEE_DEN ** 2)) revert KInvariant();
        }
        _update(balance0, balance1, _r0, _r1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice Envía a `to` el excedente de balance por sobre las reservas (tokens donados por error).
    function skim(address to) external lock {
        IERC20(token0).safeTransfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).safeTransfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    /// @notice Fuerza que las reservas igualen los balances reales.
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
