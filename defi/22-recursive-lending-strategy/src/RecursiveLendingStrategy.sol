// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {LendingPool} from "./protocol/LendingPool.sol";
import {PriceOracle} from "./protocol/PriceOracle.sol";
import {OracleDex} from "./mocks/OracleDex.sol";

/// @title RecursiveLendingStrategy — "looping" de un LST contra deuda en WETH
/// @notice Estrategia clásica de staking apalancado (ej. wstETH/WETH en Aave):
///   1. Deposita LST (que rinde staking, p. ej. 4 %) como colateral.
///   2. Pide WETH prestado (paga la tasa de préstamo, p. ej. 1-2 %).
///   3. Compra más LST con ese WETH y lo deposita. Repite.
///   Con apalancamiento L, el rendimiento sobre el capital propio es aprox.:
///   `APY_eq ≈ L·yield_LST − (L−1)·tasa_WETH`.
///
///   Dos formas de llegar al apalancamiento objetivo:
///   - `leverageLoop`: iterativo (varias vueltas borrow→swap→deposit). Sin flash loan pero caro en gas.
///   - `leverageFlash`: una sola vuelta con flash loan: pide de golpe toda la deuda objetivo,
///     compra el LST, lo deposita y pide prestado al pool para devolver el flash.
///   Y para salir: `deleverageStep` (parcial, sin flash) y `unwind` (total, con flash loan).
///
/// @dev Toda operación que termina con deuda verifica `healthFactor ≥ minHealthFactor`.
///      El riesgo principal NO es el precio de ETH (colateral y deuda se mueven juntos) sino el
///      **depeg** del LST frente a WETH y que la tasa de WETH supere el yield del LST.
contract RecursiveLendingStrategy is Ownable, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    LendingPool public immutable pool;
    PriceOracle public immutable oracle;
    OracleDex public immutable dex;
    IERC3156FlashLender public immutable lender;
    IERC20 public immutable lst; // colateral
    IERC20 public immutable weth; // deuda

    /// @notice HF mínimo tras cualquier operación (1,05 por defecto).
    uint256 public minHealthFactor = 1.05e18;
    /// @notice Slippage máximo aceptado en cada swap vs. el precio del oráculo.
    uint256 public maxSlippageBps = 100;
    /// @notice Máximo apalancamiento permitido (WAD). 8x con LTV 90 %.
    uint256 public constant MAX_LEVERAGE = 8e18;

    /// @dev Bandera de flash loan en curso (autoriza el callback).
    bool private _inFlash;

    enum Action {
        Lever,
        Unwind
    }

    event Levered(uint256 targetLeverage, uint256 achieved, uint256 iterations);
    event Unwound(uint256 lstReturned, uint256 wethReturned);

    error HealthTooLow(uint256 hf);
    error BadLeverage();
    error UntrustedLender();
    error UntrustedInitiator();
    error BadParam();

    constructor(
        LendingPool _pool,
        OracleDex _dex,
        IERC3156FlashLender _lender,
        IERC20 _lst,
        IERC20 _weth
    ) Ownable(msg.sender) {
        pool = _pool;
        oracle = _pool.oracle();
        dex = _dex;
        lender = _lender;
        lst = _lst;
        weth = _weth;
        _lst.forceApprove(address(_pool), type(uint256).max);
        _weth.forceApprove(address(_pool), type(uint256).max);
        _lst.forceApprove(address(_dex), type(uint256).max);
        _weth.forceApprove(address(_dex), type(uint256).max);
        _weth.forceApprove(address(_lender), type(uint256).max); // para que el lender cobre
    }

    // ------------------------------------------------------------------
    // Vistas
    // ------------------------------------------------------------------

    /// @notice Colateral, deuda y capital propio en USD (WAD).
    function position() public view returns (uint256 collUsd, uint256 debtUsd, uint256 equityUsd) {
        (collUsd, debtUsd,,) = pool.accountData(address(this));
        equityUsd = collUsd > debtUsd ? collUsd - debtUsd : 0;
    }

    /// @notice Apalancamiento = colateral / capital propio (WAD). 1e18 sin deuda.
    function leverage() public view returns (uint256) {
        (uint256 c,, uint256 e) = position();
        if (e == 0) return c == 0 ? WAD : type(uint256).max;
        return Math.mulDiv(c, WAD, e);
    }

    function healthFactor() public view returns (uint256) {
        return pool.healthFactor(address(this));
    }

    /// @notice Ratio de precio LST/WETH (WAD) al que la posición se vuelve liquidable.
    /// @dev HF = C·lt / D. Si el LST cae un factor x vs WETH: x·C·lt = D → x = D / (C·lt).
    function liquidationRatio() external view returns (uint256) {
        (uint256 c, uint256 d,) = position();
        if (d == 0) return 0;
        (,,,, uint256 lt,,,,,,,,) = pool.markets(address(lst));
        return Math.mulDiv(d, WAD * WAD, c * lt);
    }

    // ------------------------------------------------------------------
    // Gestión (solo owner)
    // ------------------------------------------------------------------

    function setRisk(uint256 _minHF, uint256 _maxSlippageBps) external onlyOwner {
        if (_minHF < 1.01e18 || _maxSlippageBps > 500) revert BadParam();
        minHealthFactor = _minHF;
        maxSlippageBps = _maxSlippageBps;
    }

    /// @notice Aporta LST como capital propio.
    function deposit(uint256 amount) external onlyOwner {
        lst.safeTransferFrom(msg.sender, address(this), amount);
        pool.deposit(address(lst), amount);
    }

    /// @notice Apalanca iterando borrow → swap → deposit hasta `target` o `maxIter` vueltas.
    /// @param target Apalancamiento objetivo (WAD, ej. 4e18 = 4x).
    /// @param maxIter Tope de iteraciones (control de gas).
    function leverageLoop(uint256 target, uint256 maxIter) external onlyOwner returns (uint256 iters) {
        if (target <= WAD || target > MAX_LEVERAGE) revert BadLeverage();
        uint256 pWeth = oracle.getPrice(address(weth));
        for (; iters < maxIter; iters++) {
            (uint256 c, uint256 d, uint256 limit,) = pool.accountData(address(this));
            uint256 e = c - d;
            uint256 wantColl = Math.mulDiv(target, e, WAD);
            if (c >= wantColl) break; // objetivo alcanzado
            uint256 needUsd = wantColl - c;
            // margen: usar el 95 % del poder de préstamo restante en cada vuelta
            uint256 roomUsd = limit > d ? ((limit - d) * 95) / 100 : 0;
            uint256 usd = needUsd < roomUsd ? needUsd : roomUsd;
            uint256 amt = Math.mulDiv(usd, WAD, pWeth);
            if (amt == 0) break;
            pool.borrow(address(weth), amt);
            uint256 got = _swap(weth, lst, amt);
            pool.deposit(address(lst), got);
        }
        _checkHealth();
        emit Levered(target, leverage(), iters);
    }

    /// @notice Apalanca en una sola transacción usando un flash loan de WETH.
    /// @dev Deuda objetivo ≈ (L − 1) · capital. Se toma prestado eso en flash, se compra LST,
    ///      se deposita, y se pide al pool `flash + fee` de WETH para devolverlo.
    function leverageFlash(uint256 target) external onlyOwner {
        if (target <= WAD || target > MAX_LEVERAGE) revert BadLeverage();
        (uint256 c,, uint256 e) = position();
        uint256 wantColl = Math.mulDiv(target, e, WAD);
        if (wantColl <= c) revert BadLeverage();
        uint256 amt = Math.mulDiv(wantColl - c, WAD, oracle.getPrice(address(weth)));
        _flash(amt, Action.Lever);
        _checkHealth();
        emit Levered(target, leverage(), 1);
    }

    /// @notice Desapalanca parcialmente sin flash loan: retira LST, lo vende y repaga WETH.
    /// @dev El monto debe respetar el HF (el pool revierte si el retiro deja la cuenta insolvente).
    function deleverageStep(uint256 lstAmount) external onlyOwner {
        pool.withdraw(address(lst), lstAmount);
        uint256 got = _swap(lst, weth, lstAmount);
        uint256 debt = pool.borrowBalance(address(weth), address(this));
        pool.repay(address(weth), got < debt ? got : debt, address(this));
        _checkHealth();
    }

    /// @notice Cierra toda la posición con un flash loan y devuelve todo al owner.
    function unwind() external onlyOwner {
        pool.accrue(address(weth));
        uint256 debt = pool.borrowBalance(address(weth), address(this));
        if (debt > 0) {
            _flash(debt, Action.Unwind);
        } else {
            uint256 s = pool.supplyBalance(address(lst), address(this));
            if (s > 0) pool.withdraw(address(lst), s);
        }
        uint256 l = lst.balanceOf(address(this));
        uint256 w = weth.balanceOf(address(this));
        if (l > 0) lst.safeTransfer(owner(), l);
        if (w > 0) weth.safeTransfer(owner(), w);
        emit Unwound(l, w);
    }

    /// @notice Rescata tokens sueltos (no toca la posición en el pool).
    function sweep(IERC20 token) external onlyOwner {
        token.safeTransfer(owner(), token.balanceOf(address(this)));
    }

    // ------------------------------------------------------------------
    // Flash loan
    // ------------------------------------------------------------------

    function _flash(uint256 amt, Action a) internal {
        _inFlash = true;
        lender.flashLoan(this, address(weth), amt, abi.encode(a));
        _inFlash = false;
    }

    /// @notice Callback ERC-3156. Solo acepta préstamos del lender confiable iniciados por
    ///         este contrato durante una operación del owner.
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        if (msg.sender != address(lender) || token != address(weth) || !_inFlash) revert UntrustedLender();
        if (initiator != address(this)) revert UntrustedInitiator();
        Action a = abi.decode(data, (Action));
        uint256 owed = amount + fee;
        if (a == Action.Lever) {
            uint256 got = _swap(weth, lst, amount);
            pool.deposit(address(lst), got);
            pool.borrow(address(weth), owed); // la deuda del pool reemplaza al flash
        } else {
            pool.repay(address(weth), amount, address(this));
            uint256 s = pool.supplyBalance(address(lst), address(this));
            pool.withdraw(address(lst), s);
            // vender solo el LST necesario para devolver `owed` (+ margen de slippage)
            uint256 have = weth.balanceOf(address(this));
            if (have < owed) {
                uint256 lstIn = _lstInFor(owed - have);
                if (lstIn > s) lstIn = s;
                _swap(lst, weth, lstIn);
            }
        }
        return CALLBACK_SUCCESS; // el lender cobra con transferFrom (allowance dado en el constructor)
    }

    // ------------------------------------------------------------------
    // Internos
    // ------------------------------------------------------------------

    /// @dev Swap con minOut = valor de oráculo · (1 − maxSlippage).
    function _swap(IERC20 tin, IERC20 tout, uint256 amt) internal returns (uint256) {
        uint256 fair = Math.mulDiv(amt, oracle.getPrice(address(tin)), oracle.getPrice(address(tout)));
        uint256 minOut = (fair * (BPS - maxSlippageBps)) / BPS;
        return dex.swap(address(tin), address(tout), amt, minOut);
    }

    /// @dev LST necesario para obtener `wethOut` en el peor caso aceptado (redondeo hacia arriba).
    function _lstInFor(uint256 wethOut) internal view returns (uint256) {
        uint256 fair = Math.mulDiv(wethOut, oracle.getPrice(address(weth)), oracle.getPrice(address(lst)), Math.Rounding.Ceil);
        return Math.mulDiv(fair, BPS, BPS - maxSlippageBps, Math.Rounding.Ceil);
    }

    function _checkHealth() internal view {
        uint256 hf = healthFactor();
        if (hf < minHealthFactor) revert HealthTooLow(hf);
    }
}
