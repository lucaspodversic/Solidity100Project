// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockAMM, MockOracle} from "./Mocks.sol";

/// @title VortexVault — Fondo gestionado por un agente IA con guardarraíles on-chain
/// @notice Los depositantes aportan USDC y reciben **VTX** (shares con votos, ERC20Votes). El fondo
///         provee liquidez en el par volátil WETH/USDC de un AMM. Cuánto capital va al LP lo
///         decide la **política paramétrica** (la "IA" on-chain):
///
///             vol      = EWMA(|retorno del oráculo|)                     (en bps)
///             target   = clamp(maxLp − volK·vol/1e4, minLp, maxLp)       (bps del NAV en LP)
///
///         Más volatilidad ⇒ más impermanent loss esperado ⇒ menos LP. El **agente** (modelo
///         off-chain: LLM o RL, documentado en el README) puede afinar el target dentro de una
///         banda `±aiBand` alrededor de la política. Fuera de la banda, la transacción revierte.
///
///         **Principio:** la IA propone y el contrato limita. El agente nunca elige a quién enviar
///         fondos, cuánto deslizamiento aceptar ni cuánto mover: todo lo acotan parámetros que fija
///         la DAO, y la DAO a su vez está acotada por límites duros inmutables ("constitución").
contract VortexVault is ERC20, ERC20Votes, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Params {
        uint16 minLpBps; // piso de asignación a LP
        uint16 maxLpBps; // techo de asignación a LP
        uint32 volK; // sensibilidad: bps de target por cada bps de vol, ×1e4
        uint16 aiBandBps; // margen permitido a la IA alrededor de la política
        uint16 maxSlippageBps; // deslizamiento máx. vs oráculo en swaps
        uint16 maxDeviationBps; // desvío máx. spot del AMM vs oráculo (anti-manipulación)
        uint16 maxTradeBps; // movimiento máx. por rebalanceo (% del NAV)
        uint32 cooldown; // segundos entre rebalanceos
    }

    // ---- Constitución: límites duros que ni la DAO puede superar ----
    uint16 public constant HARD_MAX_LP = 9_000;
    uint16 public constant HARD_MAX_SLIPPAGE = 300;
    uint16 public constant HARD_MAX_DEVIATION = 500;
    uint16 public constant HARD_MAX_TRADE = 5_000;
    uint16 public constant TOLERANCE_BPS = 100; // no rebalancear por menos de 1%
    uint256 public constant EWMA_ALPHA = 20; // % de peso de la observación nueva
    uint256 public constant POKE_INTERVAL = 1 hours;
    uint256 private constant VIRTUAL_SHARES = 1e3; // anti ataque de inflación

    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    MockAMM public immutable amm;
    MockOracle public immutable oracle;

    address public dao;
    address public agent;
    address public guardian;
    bool public paused;
    Params public params;

    uint256 public volBps; // EWMA de |retorno| por intervalo
    uint256 public lastPrice;
    uint256 public lastPoke;
    uint256 public lastRebalance;

    event Deposited(address indexed user, uint256 usdcIn, uint256 shares);
    event Redeemed(address indexed user, uint256 shares, uint256 usdcOut, uint256 wethOut);
    event Poked(uint256 price, uint256 retBps, uint256 volBps);
    event Rebalanced(uint256 policyTarget, uint256 aiTarget, uint256 beforeBps, uint256 afterBps);
    event ParamsSet(Params p);
    event AgentSet(address agent);
    event Paused(bool on);

    error OnlyDao();
    error OnlyAgent();
    error OnlyGuardian();
    error IsPaused();
    error BadParams();
    error AIOutOfBand(uint256 ai, uint256 policy);
    error Cooldown();
    error PriceDeviation(uint256 spot, uint256 oraclePrice);
    error ZeroShares();
    error TooSoon();

    constructor(
        IERC20 _weth,
        IERC20 _usdc,
        MockAMM _amm,
        MockOracle _oracle,
        address _dao,
        address _agent,
        address _guardian,
        Params memory p
    ) ERC20("Vortex Fund Share", "VTX") EIP712("Vortex Fund Share", "1") {
        weth = _weth;
        usdc = _usdc;
        amm = _amm;
        oracle = _oracle;
        dao = _dao;
        agent = _agent;
        guardian = _guardian;
        _setParams(p);
        lastPrice = _oracle.price();
        lastPoke = block.timestamp;
        _weth.forceApprove(address(_amm), type(uint256).max);
        _usdc.forceApprove(address(_amm), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Valuación
    // ------------------------------------------------------------------

    /// @notice Valor justo del LP (en USDC) con el método de "fair LP pricing":
    ///         `2·sqrt(k·p)·lp/supply`. Usa solo k y el precio del oráculo, NO las reservas
    ///         spot, así que mover las reservas con un swap no infla el valor (ataque Warp Finance).
    function lpValue(uint256 lp) public view returns (uint256) {
        uint256 s = amm.totalSupply();
        if (lp == 0 || s == 0) return 0;
        uint256 k = amm.reserveA() * amm.reserveB();
        uint256 poolValue = 2 * Math.sqrt(Math.mulDiv(k, oracle.price(), 1e18));
        return Math.mulDiv(poolValue, lp, s);
    }

    /// @notice NAV en USDC: USDC + WETH·p + LP (justo).
    function nav() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + (weth.balanceOf(address(this)) * oracle.price()) / 1e18
            + lpValue(amm.balanceOf(address(this)));
    }

    /// @notice % del NAV que está en LP (bps).
    function lpAllocationBps() public view returns (uint256) {
        uint256 n = nav();
        return n == 0 ? 0 : (lpValue(amm.balanceOf(address(this))) * 10_000) / n;
    }

    // ------------------------------------------------------------------
    // Depósitos y retiros
    // ------------------------------------------------------------------

    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (paused) revert IsPaused();
        shares = Math.mulDiv(amount, totalSupply() + VIRTUAL_SHARES, nav() + 1);
        if (shares == 0) revert ZeroShares();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, amount, shares);
    }

    /// @notice Retiro **in-kind** pro-rata (USDC + WETH, deshaciendo la parte del LP).
    /// @dev No usa el oráculo, así que no se puede manipular la salida. Funciona AUNQUE el fondo
    ///      esté pausado: los usuarios siempre pueden salir.
    function redeem(uint256 shares) external nonReentrant returns (uint256 usdcOut, uint256 wethOut) {
        uint256 supply = totalSupply();
        uint256 lpShare = Math.mulDiv(amm.balanceOf(address(this)), shares, supply);
        usdcOut = Math.mulDiv(usdc.balanceOf(address(this)), shares, supply);
        wethOut = Math.mulDiv(weth.balanceOf(address(this)), shares, supply);
        _burn(msg.sender, shares);
        if (lpShare > 0) {
            (uint256 a, uint256 b) = amm.removeLiquidity(lpShare);
            wethOut += a;
            usdcOut += b;
        }
        usdc.safeTransfer(msg.sender, usdcOut);
        weth.safeTransfer(msg.sender, wethOut);
        emit Redeemed(msg.sender, shares, usdcOut, wethOut);
    }

    // ------------------------------------------------------------------
    // Política (la "IA" paramétrica)
    // ------------------------------------------------------------------

    /// @notice Actualiza la volatilidad (EWMA de |retorno|). Cualquiera puede llamarlo, una vez por hora.
    function poke() external {
        if (block.timestamp < lastPoke + POKE_INTERVAL) revert TooSoon();
        uint256 p = oracle.price();
        uint256 diff = p > lastPrice ? p - lastPrice : lastPrice - p;
        uint256 ret = (diff * 10_000) / lastPrice;
        volBps = (EWMA_ALPHA * ret + (100 - EWMA_ALPHA) * volBps) / 100;
        lastPrice = p;
        lastPoke = block.timestamp;
        emit Poked(p, ret, volBps);
    }

    /// @notice Target de asignación a LP según la política.
    function policyTarget() public view returns (uint256) {
        Params memory p = params;
        uint256 cut = (uint256(p.volK) * volBps) / 1e4;
        if (cut >= p.maxLpBps) return p.minLpBps;
        uint256 t = p.maxLpBps - cut;
        return t < p.minLpBps ? p.minLpBps : t;
    }

    // ------------------------------------------------------------------
    // Ejecución del agente
    // ------------------------------------------------------------------

    /// @notice El agente propone `aiTargetBps` (de su modelo off-chain) y el contrato valida y ejecuta.
    function rebalance(uint256 aiTargetBps) external nonReentrant {
        if (msg.sender != agent) revert OnlyAgent();
        if (paused) revert IsPaused();
        Params memory p = params;
        if (block.timestamp < lastRebalance + p.cooldown) revert Cooldown();
        lastRebalance = block.timestamp;

        // 1) guarda anti-manipulación: el AMM debe estar alineado con el oráculo
        uint256 price = oracle.price();
        uint256 spot = amm.spotPrice();
        uint256 dev = spot > price ? spot - price : price - spot;
        if (dev * 10_000 > price * p.maxDeviationBps) revert PriceDeviation(spot, price);

        // 2) la IA solo puede moverse dentro de la banda de la política (y de [min, max])
        uint256 pol = policyTarget();
        uint256 lo = pol > p.aiBandBps ? pol - p.aiBandBps : 0;
        uint256 hi = pol + p.aiBandBps;
        if (aiTargetBps < lo || aiTargetBps > hi || aiTargetBps < p.minLpBps || aiTargetBps > p.maxLpBps) {
            revert AIOutOfBand(aiTargetBps, pol);
        }

        // 3) ejecutar con tope de tamaño
        uint256 n = nav();
        uint256 cur = lpAllocationBps();
        uint256 maxMove = (n * p.maxTradeBps) / 10_000;
        if (aiTargetBps > cur + TOLERANCE_BPS) {
            _increaseLp(Math.min(((aiTargetBps - cur) * n) / 10_000, maxMove), price, p.maxSlippageBps);
        } else if (aiTargetBps + TOLERANCE_BPS < cur) {
            _decreaseLp(Math.min(((cur - aiTargetBps) * n) / 10_000, maxMove), price, p.maxSlippageBps);
        }
        emit Rebalanced(pol, aiTargetBps, cur, lpAllocationBps());
    }

    /// @dev Sube el LP en `value` USDC: mitad USDC, mitad WETH (comprado si hace falta).
    function _increaseLp(uint256 value, uint256 price, uint16 slip) internal {
        uint256 usdcBal = usdc.balanceOf(address(this));
        uint256 wethBal = weth.balanceOf(address(this));
        uint256 half = value / 2;
        uint256 wethNeeded = (half * 1e18) / price;
        if (wethBal < wethNeeded) {
            uint256 usdcIn = ((wethNeeded - wethBal) * price) / 1e18;
            if (usdcIn > usdcBal) usdcIn = usdcBal / 2; // no hay suficiente: usa la mitad
            uint256 minOut = (usdcIn * 1e18 / price) * (10_000 - slip) / 10_000;
            amm.swap(address(usdc), usdcIn, minOut);
        }
        uint256 a = Math.min(weth.balanceOf(address(this)), wethNeeded);
        uint256 b = Math.min(usdc.balanceOf(address(this)), half);
        if (a > 0 && b > 0) amm.addLiquidity(a, b);
    }

    /// @dev Baja el LP en `value` USDC y deja lo liberado en USDC (sin exposición direccional).
    function _decreaseLp(uint256 value, uint256 price, uint16 slip) internal {
        uint256 lpBal = amm.balanceOf(address(this));
        uint256 lv = lpValue(lpBal);
        uint256 lp = value >= lv ? lpBal : Math.mulDiv(lpBal, value, lv);
        if (lp == 0) return;
        amm.removeLiquidity(lp);
        uint256 w = weth.balanceOf(address(this));
        if (w > 0) {
            uint256 minOut = (w * price / 1e18) * (10_000 - slip) / 10_000;
            amm.swap(address(weth), w, minOut);
        }
    }

    // ------------------------------------------------------------------
    // Gobierno
    // ------------------------------------------------------------------

    function setParams(Params calldata p) external {
        if (msg.sender != dao) revert OnlyDao();
        _setParams(p);
    }

    function _setParams(Params memory p) internal {
        if (
            p.minLpBps > p.maxLpBps || p.maxLpBps > HARD_MAX_LP || p.maxSlippageBps > HARD_MAX_SLIPPAGE
                || p.maxDeviationBps > HARD_MAX_DEVIATION || p.maxTradeBps > HARD_MAX_TRADE || p.maxTradeBps == 0
        ) revert BadParams();
        params = p;
        emit ParamsSet(p);
    }

    function setAgent(address a) external {
        if (msg.sender != dao) revert OnlyDao();
        agent = a;
        emit AgentSet(a);
    }

    /// @notice El guardián (multisig de emergencia) solo puede PAUSAR; despausar es de la DAO.
    function pause() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        paused = true;
        emit Paused(true);
    }

    function unpause() external {
        if (msg.sender != dao) revert OnlyDao();
        paused = false;
        emit Paused(false);
    }

    // ------------------------------------------------------------------
    // Votos: auto-delegación
    // ------------------------------------------------------------------

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
        if (to != address(0) && delegates(to) == address(0)) _delegate(to, to);
    }
}
