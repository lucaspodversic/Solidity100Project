// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PerpMarket} from "./perp/PerpMarket.sol";
import {PriceOracle} from "./oracle/PriceOracle.sol";
import {OracleDex} from "./mocks/OracleDex.sol";

/// @title DeltaNeutralVault — "cash & carry": ETH spot largo + short en el perp, cobra funding
/// @notice Los usuarios depositan USDC. El vault compra ETH spot con una parte y con el resto
///         pone margen para abrir un **short del mismo tamaño** en el perpetuo. La exposición
///         neta a ETH (delta) es ≈ 0: si ETH sube, el spot gana lo que el short pierde y
///         viceversa. La ganancia viene del **funding**: cuando el mercado está cargado de
///         longs (lo normal en un mercado alcista), los longs pagan y el vault cobra.
///
///  Reparto del capital desplegado C:  notional N = C / (1 + r),  margen M = C − N
///  con r = `marginRatioBps` (por defecto 50 % → 1/3 margen y 2/3 spot, short a 2x).
///
///  Riesgos que gestiona:
///   - **Liquidación del short** si ETH sube mucho (el spot gana, pero el margen se consume):
///     `rebalance()` re-arma la posición cuando el ratio de margen sale de la banda.
///   - **Funding negativo**: si los shorts pasan a pagar, la estrategia pierde plata.
///     Cualquiera puede llamar `unwindAll()` cuando el funding cae por debajo de `minFundingPerDay`.
///   - **Liquidez de retiro**: se mantiene una reserva en USDC; si no alcanza, se desarma una
///     fracción proporcional de la posición.
contract DeltaNeutralVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    IERC20 public immutable weth;
    PerpMarket public immutable perp;
    OracleDex public immutable dex;
    PriceOracle public immutable oracle;

    /// @notice Margen / notional objetivo (5000 = 50 % → short a 2x).
    uint256 public marginRatioBps = 5_000;
    /// @notice Banda fuera de la cual se permite rebalancear (cualquiera).
    uint256 public minMarginRatioBps = 2_500;
    uint256 public maxMarginRatioBps = 10_000;
    /// @notice USDC ocioso que se mantiene para retiros (% de totalAssets).
    uint256 public reserveBps = 1_000;
    /// @notice Tolerancia de slippage para swaps y para el precio del perp.
    uint256 public maxSlippageBps = 100;
    /// @notice Si el funding/día (WAD) cae por debajo de esto, cualquiera puede desarmar.
    int256 public minFundingPerDay = 0;
    /// @notice false = posición desarmada; los depósitos quedan en USDC.
    bool public hedged = true;

    event Deployed(uint256 usdcIn, uint256 ethBought, uint256 marginAdded);
    event Unwound(uint256 fracWad, uint256 usdcOut);
    event Rebalanced(uint256 marginRatioBefore, uint256 marginRatioAfter);
    event HedgeToggled(bool hedged);

    error RebalanceNotNeeded(uint256 ratioBps);
    error FundingStillPositive(int256 fundingPerDay);
    error InsufficientLiquidity(uint256 available, uint256 needed);

    constructor(IERC20 usdc_, IERC20 weth_, PerpMarket perp_, OracleDex dex_, PriceOracle oracle_)
        ERC4626(usdc_)
        ERC20("Delta Neutral ETH Vault", "dnETH")
        Ownable(msg.sender)
    {
        weth = weth_;
        perp = perp_;
        dex = dex_;
        oracle = oracle_;
        usdc_.forceApprove(address(perp_), type(uint256).max);
        usdc_.forceApprove(address(dex_), type(uint256).max);
        weth_.forceApprove(address(dex_), type(uint256).max);
    }

    // =====================================================================
    // Contabilidad
    // =====================================================================

    /// @notice Valor **de liquidación**: USDC ocioso + lo que daría vender el spot en el DEX +
    ///         equity del perp menos la fee de cerrarlo.
    /// @dev Valuar a precio de salida (y no a mark-to-market) hace que cada usuario que se va
    ///      pague su propio costo de desarme: si no, el último en salir no podría cobrar lo que
    ///      `previewRedeem` le promete y los costos se socializarían entre los que se quedan.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 ethBal = weth.balanceOf(address(this));
        uint256 spot = ethBal == 0 ? 0 : dex.quote(address(weth), asset(), ethBal);
        int256 eq = perp.equity(address(this));
        uint256 closeFee = perp.notional(address(this)) * perp.tradingFeeBps() / BPS;
        eq -= int256(closeFee);
        return idle + spot + (eq > 0 ? uint256(eq) : 0);
    }

    /// @notice Exposición neta a ETH (WAD): spot + size del perp (negativo). ≈ 0 si está cubierto.
    function delta() public view returns (int256) {
        return int256(weth.balanceOf(address(this))) + perp.positionOf(address(this)).size;
    }

    /// @notice Equity del perp / notional del short, en bps (type(uint).max si no hay short).
    function marginRatio() public view returns (uint256) {
        uint256 n = perp.notional(address(this));
        if (n == 0) return type(uint256).max;
        int256 eq = perp.equity(address(this));
        return eq <= 0 ? 0 : uint256(eq) * BPS / n;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // =====================================================================
    // Hooks ERC-4626
    // =====================================================================

    /// @dev Después de recibir el depósito se despliega lo que exceda la reserva.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        super._deposit(caller, receiver, assets, shares);
        if (hedged) _deployExcess();
    }

    /// @dev Antes de pagar, se asegura liquidez desarmando una fracción si hace falta.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) {
            uint256 deployed = totalAssets() - idle;
            // +1 % de margen para cubrir fees/slippage del desarme
            uint256 frac = Math.min(WAD, (assets - idle) * WAD * 101 / 100 / deployed);
            _unwind(frac);
            idle = IERC20(asset()).balanceOf(address(this));
            if (idle < assets) revert InsufficientLiquidity(idle, assets);
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // =====================================================================
    // Gestión de la posición
    // =====================================================================

    /// @notice Re-arma la posición (desarma todo y vuelve a desplegar) para volver al ratio
    ///         objetivo. Cualquiera puede llamarla si el ratio salió de la banda; el owner, siempre.
    function rebalance() external nonReentrant {
        uint256 before = marginRatio();
        if (msg.sender != owner() && before >= minMarginRatioBps && before <= maxMarginRatioBps) {
            revert RebalanceNotNeeded(before);
        }
        _unwind(WAD);
        if (hedged) _deployExcess();
        emit Rebalanced(before, marginRatio());
    }

    /// @notice Desarma todo y queda en USDC. Owner siempre; cualquiera si el funding se dio vuelta.
    function unwindAll() external nonReentrant {
        int256 f = perp.fundingRatePerDay();
        if (msg.sender != owner() && f >= minFundingPerDay) revert FundingStillPositive(f);
        _unwind(WAD);
        hedged = false;
        emit HedgeToggled(false);
    }

    /// @notice El owner vuelve a armar la estrategia.
    function redeploy() external onlyOwner nonReentrant {
        hedged = true;
        _deployExcess();
        emit HedgeToggled(true);
    }

    function setParams(uint256 marginRatio_, uint256 minR, uint256 maxR, uint256 reserve, int256 minFunding)
        external
        onlyOwner
    {
        require(minR < marginRatio_ && marginRatio_ < maxR && reserve <= 5_000, "params");
        require(marginRatio_ >= 2_000, "leverage > 5x"); // muy cerca del margen inicial del perp
        marginRatioBps = marginRatio_;
        minMarginRatioBps = minR;
        maxMarginRatioBps = maxR;
        reserveBps = reserve;
        minFundingPerDay = minFunding;
    }

    // ---------------------------------------------------------------------
    // Internos
    // ---------------------------------------------------------------------

    function _deployExcess() internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 reserve = totalAssets() * reserveBps / BPS;
        if (idle <= reserve) return;
        uint256 amount = idle - reserve;

        uint256 n = amount * BPS / (BPS + marginRatioBps); // a spot
        uint256 m = amount - n; // a margen
        if (n == 0 || m == 0) return;

        // 1) comprar spot con protección de slippage contra el precio del oráculo
        uint256 price = _ethPrice();
        uint256 fair = n * 1e12 * WAD / price;
        uint256 ethOut = dex.swap(asset(), address(weth), n, fair * (BPS - maxSlippageBps) / BPS);
        // 2) margen y short del MISMO tamaño que el spot comprado → delta 0
        perp.depositMargin(m);
        perp.trade(-int256(ethOut), price * (BPS - maxSlippageBps) / BPS);
        emit Deployed(amount, ethOut, m);
    }

    /// @dev Desarma una fracción `frac` (WAD) de la posición: recompra el short, retira margen
    ///      proporcional y vende el spot proporcional.
    function _unwind(uint256 frac) internal {
        if (frac == 0) return;
        uint256 before = IERC20(asset()).balanceOf(address(this));
        uint256 price = _ethPrice();
        int256 size = perp.positionOf(address(this)).size;

        if (size != 0) {
            int256 close = frac == WAD ? -size : -size * int256(frac) / int256(WAD);
            if (close != 0) perp.trade(close, price * (BPS + maxSlippageBps) / BPS);
        }
        int256 m = perp.margin(address(this));
        if (m > 0) {
            uint256 out = frac == WAD ? uint256(m) : uint256(m) * frac / WAD;
            if (out > 0) perp.withdrawMargin(out);
        }
        uint256 ethBal = weth.balanceOf(address(this));
        uint256 sell = frac == WAD ? ethBal : ethBal * frac / WAD;
        if (sell > 0) {
            uint256 fair = sell * price / WAD / 1e12;
            dex.swap(address(weth), asset(), sell, fair * (BPS - maxSlippageBps) / BPS);
        }
        emit Unwound(frac, IERC20(asset()).balanceOf(address(this)) - before);
    }

    function _ethPrice() internal view returns (uint256) {
        return oracle.getPrice(address(weth));
    }
}
