// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOracle, Median} from "./IOracle.sol";

/// @title StakingOracle — Arquitectura 2: reporteros sin permiso con stake y slashing
/// @notice Cualquiera puede ser reportero depositando `MIN_STAKE` ETH. El tiempo se divide
///         en **épocas**; en cada época los reporteros publican un valor. Al cerrar la
///         época, `finalize` calcula la mediana y:
///           - **recorta (slash)** un 10% del stake a quienes se desviaron > `MAX_DEV_BPS`;
///           - reparte lo recortado entre los reporteros precisos.
/// @dev Seguridad económica: mentir cuesta stake, y para mover la mediana hay que controlar
///      la mayoría del conjunto de reporteros de la época (costo = mitad del stake total).
///      Para retirar el stake hay un **unbonding**: no se puede reportar mal y salir enseguida.
contract StakingOracle is IOracle, ReentrancyGuard {
    uint256 public constant MIN_STAKE = 1 ether;
    uint256 public constant EPOCH = 1 hours;
    uint256 public constant MAX_DEV_BPS = 100; // 1%
    uint256 public constant SLASH_BPS = 1_000; // 10%
    uint256 public constant UNBONDING = 2 days;
    uint256 public constant MAX_REPORTERS_PER_EPOCH = 25;
    uint256 public constant MIN_REPORTS = 3;

    struct Staker {
        uint256 stake;
        uint256 unbondAt; // 0 = activo
    }

    mapping(address => Staker) public stakers;
    /// @notice época => reportero => valor (+1 para distinguir "no reportó")
    mapping(uint256 => mapping(address => uint256)) public reportOf;
    mapping(uint256 => address[]) internal epochReporters;
    mapping(uint256 => bool) public finalized;
    /// @notice ETH de recompensas pendiente de retiro (pull).
    mapping(address => uint256) public rewards;

    uint256 public lastValue;
    uint256 public lastUpdated;

    event Staked(address indexed who, uint256 amount);
    event UnbondRequested(address indexed who, uint256 at);
    event Withdrawn(address indexed who, uint256 amount);
    event Reported(uint256 indexed epoch, address indexed who, uint256 value);
    event Finalized(uint256 indexed epoch, uint256 median, uint256 slashed);
    event Slashed(uint256 indexed epoch, address indexed who, uint256 amount);

    error InsufficientStake();
    error AlreadyReported();
    error EpochNotOver();
    error AlreadyFinalized();
    error NotEnoughReports();
    error Unbonding();
    error EpochFull();
    error NotReady();
    error NoData();

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH;
    }

    function stake() external payable {
        Staker storage s = stakers[msg.sender];
        if (s.unbondAt != 0) revert Unbonding();
        s.stake += msg.value;
        if (s.stake < MIN_STAKE) revert InsufficientStake();
        emit Staked(msg.sender, msg.value);
    }

    /// @notice Pide retirar el stake; desde ahora no puede reportar.
    function requestUnbond() external {
        Staker storage s = stakers[msg.sender];
        if (s.stake == 0) revert InsufficientStake();
        s.unbondAt = block.timestamp + UNBONDING;
        emit UnbondRequested(msg.sender, s.unbondAt);
    }

    /// @notice Retira stake tras el unbonding, más las recompensas.
    function withdraw() external nonReentrant {
        Staker storage s = stakers[msg.sender];
        uint256 amt = rewards[msg.sender];
        rewards[msg.sender] = 0;
        if (s.unbondAt != 0) {
            if (block.timestamp < s.unbondAt) revert NotReady();
            amt += s.stake;
            s.stake = 0;
            s.unbondAt = 0;
        }
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "envio fallido");
        emit Withdrawn(msg.sender, amt);
    }

    /// @notice Publica el valor de la época actual (uno por reportero).
    function report(uint256 value) external {
        Staker storage s = stakers[msg.sender];
        if (s.stake < MIN_STAKE) revert InsufficientStake();
        if (s.unbondAt != 0) revert Unbonding();
        uint256 e = currentEpoch();
        if (reportOf[e][msg.sender] != 0) revert AlreadyReported();
        if (epochReporters[e].length >= MAX_REPORTERS_PER_EPOCH) revert EpochFull();
        reportOf[e][msg.sender] = value + 1;
        epochReporters[e].push(msg.sender);
        emit Reported(e, msg.sender, value);
    }

    /// @notice Cierra una época pasada: mediana, slashing y recompensas (permisionless).
    function finalize(uint256 e) external {
        if (e >= currentEpoch()) revert EpochNotOver();
        if (finalized[e]) revert AlreadyFinalized();
        address[] memory rs = epochReporters[e];
        uint256 n = rs.length;
        if (n < MIN_REPORTS) revert NotEnoughReports();
        finalized[e] = true;

        uint256[] memory vals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) vals[i] = reportOf[e][rs[i]] - 1;
        // copia (Median.of ordena in-place)
        uint256[] memory sorted = new uint256[](n);
        for (uint256 i = 0; i < n; i++) sorted[i] = vals[i];
        uint256 med = Median.compute(sorted);

        // 1) slash de outliers
        uint256 pot;
        uint256 honestCount;
        bool[] memory honest = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 dev = vals[i] > med ? vals[i] - med : med - vals[i];
            if (dev * 10_000 > med * MAX_DEV_BPS) {
                uint256 cut = (stakers[rs[i]].stake * SLASH_BPS) / 10_000;
                stakers[rs[i]].stake -= cut;
                pot += cut;
                emit Slashed(e, rs[i], cut);
            } else {
                honest[i] = true;
                honestCount++;
            }
        }
        // 2) reparto entre los honestos (honestCount >= 1: el que está en la mediana es honesto)
        if (pot > 0) {
            uint256 each = pot / honestCount;
            for (uint256 i = 0; i < n; i++) {
                if (honest[i]) rewards[rs[i]] += each;
            }
        }
        // solo avanza el valor publicado si la época es más nueva
        if ((e + 1) * EPOCH > lastUpdated) {
            lastValue = med;
            lastUpdated = (e + 1) * EPOCH;
        }
        emit Finalized(e, med, pot);
    }

    /// @inheritdoc IOracle
    function latest() external view returns (uint256, uint256) {
        if (lastUpdated == 0) revert NoData();
        return (lastValue, lastUpdated);
    }

    function reportersOf(uint256 e) external view returns (address[] memory) {
        return epochReporters[e];
    }
}
