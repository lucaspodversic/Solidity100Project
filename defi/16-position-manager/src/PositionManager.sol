// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVenue} from "./venues/IVenue.sol";

/// @title PositionManager — administra una cartera de un activo repartida entre protocolos
/// @notice El owner define pesos objetivo (en bps) por venue. Cuando la cartera se desvía más
///         que `driftThresholdBps` (porque un venue rindió más que otro, o hubo depósitos y
///         retiros), un keeper puede llamar a `rebalance()`, que:
///           1) retira el excedente de los venues sobreponderados y
///           2) deposita en los subponderados,
///         verificando al final que el valor total no cayó más que `maxLossBps`.
/// @dev Lo que no se asigna a venues (10 000 − Σ pesos) queda como colchón líquido ("idle").
contract PositionManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    /// @notice Tope de venues: acota el gas de los loops (evita DoS por array gigante).
    uint256 public constant MAX_VENUES = 8;

    /// @notice Configuración de cada venue.
    struct VenueConfig {
        IVenue venue;
        uint16 targetBps;
    }

    /// @notice Activo administrado (p. ej. USDC).
    IERC20 public immutable asset;
    /// @notice Venues registrados.
    VenueConfig[] public venues;
    /// @notice Bot autorizado a rebalancear (además del owner).
    address public keeper;
    /// @notice Desvío mínimo (bps de la cartera) para permitir rebalancear: anti-griefing de gas.
    uint256 public driftThresholdBps = 200;
    /// @notice Pérdida máxima tolerada en un rebalanceo (fees de salida, slippage).
    uint256 public maxLossBps = 10;
    /// @notice Tiempo mínimo entre rebalanceos.
    uint256 public cooldown = 1 hours;
    /// @notice Timestamp del último rebalanceo.
    uint256 public lastRebalance;

    event VenueAdded(uint256 indexed index, address venue, string name);
    event TargetsSet(uint16[] targets);
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount, address to);
    event Rebalanced(uint256 valueBefore, uint256 valueAfter, uint256 moved);
    event EmergencyExit(uint256 indexed index, uint256 recovered);
    event ParamsSet(address keeper, uint256 drift, uint256 maxLoss, uint256 cooldown);

    error WrongAsset();
    error TooManyVenues();
    error BadTargets();
    error NotKeeper();
    error NoRebalanceNeeded();
    error CooldownActive();
    error LossTooHigh(uint256 before, uint256 afterValue);
    error InsufficientLiquidity(uint256 requested, uint256 available);

    constructor(IERC20 _asset, address _keeper) Ownable(msg.sender) {
        asset = _asset;
        keeper = _keeper;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    // ------------------------------------------------------------------
    // Administración
    // ------------------------------------------------------------------

    /// @notice Registra un venue con peso 0 (hay que llamar a `setTargets` después).
    function addVenue(IVenue v) external onlyOwner {
        if (v.asset() != address(asset)) revert WrongAsset();
        if (venues.length >= MAX_VENUES) revert TooManyVenues();
        venues.push(VenueConfig(v, 0));
        asset.forceApprove(address(v), type(uint256).max);
        emit VenueAdded(venues.length - 1, address(v), v.name());
    }

    /// @notice Pesos objetivo, uno por venue. La suma puede ser < 10 000 (resto = colchón).
    function setTargets(uint16[] calldata t) external onlyOwner {
        if (t.length != venues.length) revert BadTargets();
        uint256 sum;
        for (uint256 i; i < t.length; i++) {
            sum += t[i];
            venues[i].targetBps = t[i];
        }
        if (sum > BPS) revert BadTargets();
        emit TargetsSet(t);
    }

    function setParams(address _keeper, uint256 drift, uint256 maxLoss, uint256 _cooldown) external onlyOwner {
        if (maxLoss > 500 || drift > BPS) revert BadTargets(); // pérdida máx. 5 %
        keeper = _keeper;
        driftThresholdBps = drift;
        maxLossBps = maxLoss;
        cooldown = _cooldown;
        emit ParamsSet(_keeper, drift, maxLoss, _cooldown);
    }

    // ------------------------------------------------------------------
    // Fondos
    // ------------------------------------------------------------------

    /// @notice Ingresa fondos al colchón. Se reparten en el próximo `rebalance`.
    function deposit(uint256 amount) external onlyOwner nonReentrant {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(amount);
    }

    /// @notice Retira `amount`: primero del colchón y después de los venues, en orden.
    function withdraw(uint256 amount, address to) external onlyOwner nonReentrant {
        uint256 idle = asset.balanceOf(address(this));
        for (uint256 i; i < venues.length && idle < amount; i++) {
            IVenue v = venues[i].venue;
            uint256 take = _min(amount - idle, v.maxWithdraw());
            if (take > 0) idle += v.withdraw(take);
        }
        if (idle < amount) revert InsufficientLiquidity(amount, idle);
        asset.safeTransfer(to, amount);
        emit Withdrawn(amount, to);
    }

    /// @notice Saca TODO de un venue (p. ej. si se sospecha un hackeo) y le pone peso 0.
    /// @dev No respeta `maxLossBps`: en una emergencia es preferible salir con pérdida.
    function emergencyExit(uint256 i) external onlyOwner nonReentrant {
        IVenue v = venues[i].venue;
        venues[i].targetBps = 0;
        uint256 got = v.withdraw(v.maxWithdraw());
        emit EmergencyExit(i, got);
    }

    // ------------------------------------------------------------------
    // Rebalanceo
    // ------------------------------------------------------------------

    /// @notice Ejecuta el rebalanceo hacia los pesos objetivo.
    /// @dev Retirar primero y depositar después garantiza que haya liquidez para los depósitos.
    function rebalance() external onlyKeeper nonReentrant {
        // El primer rebalanceo (lastRebalance == 0) no espera el cooldown.
        if (lastRebalance != 0 && block.timestamp < lastRebalance + cooldown) revert CooldownActive();
        if (!needsRebalance()) revert NoRebalanceNeeded();
        uint256 before = totalValue();
        uint256 n = venues.length;
        uint256 moved;

        // 1) Retirar excedentes
        for (uint256 i; i < n; i++) {
            IVenue v = venues[i].venue;
            uint256 cur = v.totalAssets();
            uint256 tgt = (before * venues[i].targetBps) / BPS;
            if (cur > tgt) {
                uint256 take = _min(cur - tgt, v.maxWithdraw());
                if (take > 0) moved += v.withdraw(take);
            }
        }
        // 2) Cubrir déficits con lo que hay en el colchón
        for (uint256 i; i < n; i++) {
            IVenue v = venues[i].venue;
            uint256 cur = v.totalAssets();
            uint256 tgt = (before * venues[i].targetBps) / BPS;
            if (cur < tgt) {
                uint256 put = _min(tgt - cur, asset.balanceOf(address(this)));
                if (put > 0) {
                    v.deposit(put);
                    moved += put;
                }
            }
        }
        // 3) Control de pérdidas: un venue con fee de salida oculto no puede drenarnos en silencio
        uint256 afterValue = totalValue();
        if (afterValue * BPS < before * (BPS - maxLossBps)) revert LossTooHigh(before, afterValue);
        lastRebalance = block.timestamp;
        emit Rebalanced(before, afterValue, moved);
    }

    // ------------------------------------------------------------------
    // Vistas
    // ------------------------------------------------------------------

    /// @notice Valor total: colchón + Σ posiciones.
    function totalValue() public view returns (uint256 v) {
        v = asset.balanceOf(address(this));
        for (uint256 i; i < venues.length; i++) {
            v += venues[i].venue.totalAssets();
        }
    }

    /// @notice Peso actual (bps) de cada venue.
    function currentAllocation() public view returns (uint256[] memory bps) {
        uint256 tv = totalValue();
        bps = new uint256[](venues.length);
        if (tv == 0) return bps;
        for (uint256 i; i < venues.length; i++) {
            bps[i] = (venues[i].venue.totalAssets() * BPS) / tv;
        }
    }

    /// @notice true si algún venue se desvió más que el umbral de su peso objetivo.
    function needsRebalance() public view returns (bool) {
        uint256[] memory cur = currentAllocation();
        for (uint256 i; i < cur.length; i++) {
            uint256 t = venues[i].targetBps;
            uint256 d = cur[i] > t ? cur[i] - t : t - cur[i];
            if (d > driftThresholdBps) return true;
        }
        return false;
    }

    function venuesCount() external view returns (uint256) {
        return venues.length;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
