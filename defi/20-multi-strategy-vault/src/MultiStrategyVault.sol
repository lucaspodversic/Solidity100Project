// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategy} from "./IStrategy.sol";

/// @title MultiStrategyVault — vault ERC-4626 que reparte capital entre varias estrategias
/// @notice Inspirado en Yearn v2/v3:
///  - **Contabilidad por deuda:** el vault registra cuánto le "prestó" a cada estrategia (`debt`).
///    `totalAssets = idle + totalDebt`. Las ganancias/pérdidas reales entran recién con `report()`.
///  - **Asignación por APY con topes:** `allocate()` ordena las estrategias por APY y llena cada
///    una hasta su `capBps` del total, dejando un colchón `reserveBps` ocioso para retiros.
///  - **Cola de retiro:** si el colchón no alcanza, se des-invierte en el orden de `withdrawQueue`.
///  - **Performance fee** sobre ganancias reportadas, cobrada acuñando shares al tesoro.
///  - **Desbloqueo lineal** de ganancias (anti-sandwich del `report`).
contract MultiStrategyVault is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_STRATEGIES = 10;
    uint256 public constant LOCK_PERIOD = 1 days;

    struct StrategyParams {
        bool active; // habilitada
        uint16 capBps; // tope sobre totalAssets
        uint256 debt; // capital asignado según el vault
        uint256 lastReport; // timestamp
    }

    mapping(IStrategy => StrategyParams) public strategies;
    IStrategy[] public strategyList; // todas las agregadas (activas o revocadas con deuda 0)
    IStrategy[] public withdrawQueue; // orden de des-inversión

    uint256 public totalDebt;
    uint256 public reserveBps = 500; // 5 % ocioso
    uint256 public perfFeeBps = 1_000; // 10 %
    address public treasury;

    uint256 public lockedProfit;
    uint256 public lastProfitUpdate;

    event StrategyAdded(IStrategy indexed s, uint16 capBps);
    event StrategyRevoked(IStrategy indexed s);
    event Reported(IStrategy indexed s, uint256 gain, uint256 loss, uint256 feeShares);
    event Allocated(IStrategy indexed s, uint256 oldDebt, uint256 newDebt);

    error BadStrategy();
    error TooMany();
    error BadParam();
    error InsufficientLiquidity(uint256 needed, uint256 got);
    error HasDebt();

    constructor(IERC20 asset_, address _treasury) ERC20("Multi-Strategy USDC", "msUSDC") ERC4626(asset_) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
        treasury = _treasury;
    }

    // ------------------------------------------------------------------
    // Vistas
    // ------------------------------------------------------------------

    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Ganancia aún bloqueada (decrece linealmente).
    function lockedNow() public view returns (uint256) {
        uint256 dt = block.timestamp - lastProfitUpdate;
        if (dt >= LOCK_PERIOD) return 0;
        return (lockedProfit * (LOCK_PERIOD - dt)) / LOCK_PERIOD;
    }

    function totalAssets() public view override returns (uint256) {
        return idle() + totalDebt - lockedNow();
    }

    function strategyCount() external view returns (uint256) {
        return strategyList.length;
    }

    /// @notice APY ponderado por deuda (bps) — métrica para dashboards.
    function weightedApy() external view returns (uint256) {
        uint256 ta = idle() + totalDebt;
        if (ta == 0) return 0;
        uint256 acc;
        for (uint256 i; i < strategyList.length; i++) {
            IStrategy s = strategyList[i];
            acc += strategies[s].debt * s.apyBps();
        }
        return acc / ta;
    }

    // ------------------------------------------------------------------
    // Gobernanza
    // ------------------------------------------------------------------

    /// @notice Agrega una estrategia al final de la cola de retiro.
    function addStrategy(IStrategy s, uint16 capBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (s.asset() != asset() || strategies[s].active || strategies[s].lastReport != 0) revert BadStrategy();
        if (capBps > BPS) revert BadParam();
        if (strategyList.length >= MAX_STRATEGIES) revert TooMany();
        strategies[s] = StrategyParams({active: true, capBps: capBps, debt: 0, lastReport: block.timestamp});
        strategyList.push(s);
        withdrawQueue.push(s);
        emit StrategyAdded(s, capBps);
    }

    function setCap(IStrategy s, uint16 capBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!strategies[s].active || capBps > BPS) revert BadParam();
        strategies[s].capBps = capBps;
    }

    /// @notice Reordena la cola de retiro (debe ser una permutación de las estrategias activas).
    function setWithdrawQueue(IStrategy[] calldata q) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (q.length != withdrawQueue.length) revert BadParam();
        for (uint256 i; i < q.length; i++) {
            if (!strategies[q[i]].active) revert BadParam();
            for (uint256 j; j < i; j++) if (q[j] == q[i]) revert BadParam();
        }
        withdrawQueue = q;
    }

    /// @notice Retira todo de una estrategia y la desactiva (reconoce la pérdida si devuelve menos).
    function revokeStrategy(IStrategy s) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        StrategyParams storage p = strategies[s];
        if (!p.active) revert BadStrategy();
        uint256 got = s.divest(type(uint256).max);
        if (s.totalAssets() > 0) revert HasDebt(); // ilíquida: no se puede revocar todavía
        // Toda diferencia entre deuda y lo devuelto es pérdida realizada (o ganancia si sobra).
        totalDebt -= p.debt;
        if (got > p.debt) _lockProfit(got - p.debt);
        p.debt = 0;
        p.active = false;
        _removeFromQueue(s);
        emit StrategyRevoked(s);
    }

    function setParams(uint256 _reserveBps, uint256 _perfFeeBps, address _treasury)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_reserveBps > BPS || _perfFeeBps > 3_000) revert BadParam();
        reserveBps = _reserveBps;
        perfFeeBps = _perfFeeBps;
        treasury = _treasury;
    }

    // ------------------------------------------------------------------
    // Keeper
    // ------------------------------------------------------------------

    /// @notice Reconoce la ganancia/pérdida de una estrategia comparando su valor con la deuda.
    /// @dev Ganancia: se suma a la deuda, se bloquea (desbloqueo lineal) y paga performance fee
    ///      en shares. Pérdida: baja la deuda en el acto (los holders la absorben ya; demorarla
    ///      permitiría a los informados salir antes a precio viejo).
    function report(IStrategy s) public onlyRole(KEEPER_ROLE) returns (uint256 gain, uint256 loss) {
        StrategyParams storage p = strategies[s];
        if (!p.active) revert BadStrategy();
        uint256 value = s.totalAssets();
        uint256 feeShares;
        if (value > p.debt) {
            gain = value - p.debt;
            uint256 fee = (gain * perfFeeBps) / BPS;
            // shares del tesoro calculados a precio pre-ganancia (la ganancia aún no está en totalAssets)
            if (fee > 0) {
                feeShares = _convertToShares(fee, Math.Rounding.Floor);
                _mint(treasury, feeShares);
            }
            p.debt = value;
            totalDebt += gain;
            _lockProfit(gain);
        } else if (value < p.debt) {
            loss = p.debt - value;
            p.debt = value;
            totalDebt -= loss;
            // la pérdida se come primero la ganancia aún bloqueada
            uint256 locked = lockedNow();
            uint256 eat = loss < locked ? loss : locked;
            lockedProfit = locked - eat;
            lastProfitUpdate = block.timestamp;
        }
        p.lastReport = block.timestamp;
        emit Reported(s, gain, loss, feeShares);
    }

    /// @notice Reporta todas las estrategias activas.
    function reportAll() external onlyRole(KEEPER_ROLE) {
        for (uint256 i; i < withdrawQueue.length; i++) report(withdrawQueue[i]);
    }

    /// @notice Reasigna el capital: mayor APY primero, respetando topes y la reserva ociosa.
    function allocate() external onlyRole(KEEPER_ROLE) nonReentrant {
        uint256 n = withdrawQueue.length;
        IStrategy[] memory sorted = new IStrategy[](n);
        for (uint256 i; i < n; i++) sorted[i] = withdrawQueue[i];
        // insertion sort por APY descendente (n ≤ 10)
        for (uint256 i = 1; i < n; i++) {
            IStrategy k = sorted[i];
            uint256 ka = k.apyBps();
            uint256 j = i;
            while (j > 0 && sorted[j - 1].apyBps() < ka) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = k;
        }
        uint256 gross = idle() + totalDebt;
        uint256 remaining = (gross * (BPS - reserveBps)) / BPS;
        uint256[] memory target = new uint256[](n);
        for (uint256 i; i < n; i++) {
            uint256 cap = (gross * strategies[sorted[i]].capBps) / BPS;
            target[i] = cap < remaining ? cap : remaining;
            remaining -= target[i];
        }
        // fase 1: sacar de las sobre-asignadas (libera liquidez)
        for (uint256 i; i < n; i++) {
            StrategyParams storage p = strategies[sorted[i]];
            if (p.debt > target[i]) {
                uint256 old = p.debt;
                uint256 got = sorted[i].divest(old - target[i]);
                p.debt -= got;
                totalDebt -= got;
                emit Allocated(sorted[i], old, p.debt);
            }
        }
        // fase 2: poner en las sub-asignadas (en orden de APY, con lo ocioso disponible)
        IERC20 a = IERC20(asset());
        for (uint256 i; i < n; i++) {
            StrategyParams storage p = strategies[sorted[i]];
            if (p.debt < target[i]) {
                uint256 amt = target[i] - p.debt;
                uint256 avail = idle();
                if (amt > avail) amt = avail;
                if (amt == 0) continue;
                uint256 old = p.debt;
                a.safeTransfer(address(sorted[i]), amt);
                sorted[i].invest(amt);
                p.debt += amt;
                totalDebt += amt;
                emit Allocated(sorted[i], old, p.debt);
            }
        }
    }

    // ------------------------------------------------------------------
    // Hooks ERC-4626
    // ------------------------------------------------------------------

    /// @dev Si el ocioso no alcanza, des-invierte siguiendo `withdrawQueue`.
    ///      Si una estrategia devuelve menos de lo pedido (iliquidez) se pasa a la siguiente;
    ///      si al final no alcanza, revierte (nadie sale a costa de los demás).
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        uint256 have = idle();
        for (uint256 i; i < withdrawQueue.length && have < assets; i++) {
            IStrategy s = withdrawQueue[i];
            StrategyParams storage p = strategies[s];
            uint256 want = assets - have;
            if (want > p.debt) want = p.debt;
            if (want == 0) continue;
            uint256 got = s.divest(want);
            p.debt -= got;
            totalDebt -= got;
            have += got;
        }
        if (have < assets) revert InsufficientLiquidity(assets, have);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ------------------------------------------------------------------
    // Internos
    // ------------------------------------------------------------------

    function _lockProfit(uint256 amt) internal {
        lockedProfit = lockedNow() + amt;
        lastProfitUpdate = block.timestamp;
    }

    function _removeFromQueue(IStrategy s) internal {
        uint256 n = withdrawQueue.length;
        for (uint256 i; i < n; i++) {
            if (withdrawQueue[i] == s) {
                for (uint256 j = i; j + 1 < n; j++) withdrawQueue[j] = withdrawQueue[j + 1];
                withdrawQueue.pop();
                return;
            }
        }
    }
}
