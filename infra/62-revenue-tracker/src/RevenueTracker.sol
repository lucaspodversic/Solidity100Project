// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RevenueTracker — Tesorería que registra y reparte ingresos por comisiones
/// @notice Los contratos de un protocolo (DEX, lending, marketplace...) se registran
///         como "fuentes" y envían sus comisiones a esta tesorería mediante `recordFee`.
///         El tracker guarda:
///           - total histórico por token,
///           - total por fuente y token,
///           - serie diaria por token (para dashboards / APR),
///         y reparte lo acumulado entre beneficiarios según `shares` (modelo "pull").
/// @dev Diseño "pull payment": nadie recibe tokens automáticamente; cada beneficiario
///      reclama con `claim`. Esto evita que un beneficiario que revierte bloquee a los demás.
///      Contabilidad de reparto estilo "acumulador por share" (como MasterChef):
///        accPerShare[token] += monto * 1e18 / totalShares
///        pendiente(b) = shares[b] * accPerShare / 1e18 - debt[b]
contract RevenueTracker is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Dirección especial que representa ETH nativo.
    address public constant ETH = address(0);
    /// @notice Duración de una "época" para la serie temporal (1 día).
    uint256 public constant EPOCH = 1 days;
    /// @dev Precisión del acumulador.
    uint256 private constant PRECISION = 1e18;

    /// @notice Información de una fuente de ingresos.
    struct Source {
        bool active;
        string name;
    }

    /// @notice Fuentes registradas.
    mapping(address => Source) public sources;
    /// @notice Lista de fuentes para iterar desde el front.
    address[] public sourceList;
    /// @notice Tokens que alguna vez recibieron ingresos.
    address[] public tokenList;
    mapping(address => bool) public isTrackedToken;

    /// @notice Total histórico por token.
    mapping(address => uint256) public totalRevenue;
    /// @notice fuente => token => total.
    mapping(address => mapping(address => uint256)) public revenueBySource;
    /// @notice token => día (timestamp / EPOCH) => total del día.
    mapping(address => mapping(uint256 => uint256)) public dailyRevenue;

    // ------- reparto -------
    /// @notice Shares de cada beneficiario.
    mapping(address => uint256) public shares;
    /// @notice Suma de shares.
    uint256 public totalShares;
    address[] public beneficiaries;
    /// @notice token => acumulado por share (escala 1e18).
    mapping(address => uint256) public accPerShare;
    /// @notice token => beneficiario => deuda contable.
    mapping(address => mapping(address => uint256)) public debt;
    /// @notice token => beneficiario => saldo ya "cristalizado" al cambiar shares.
    mapping(address => mapping(address => uint256)) public credited;

    event SourceSet(address indexed source, string name, bool active);
    event FeeRecorded(address indexed source, address indexed token, uint256 amount, uint256 indexed day);
    event SharesSet(address indexed beneficiary, uint256 shares);
    event Claimed(address indexed beneficiary, address indexed token, uint256 amount);

    error NotSource();
    error BadAmount();
    error NoShares();
    error TransferFailed();

    constructor(address owner_) Ownable(owner_) {}

    // ------------------------------------------------------------------
    // Administración
    // ------------------------------------------------------------------

    /// @notice Registra o (des)activa una fuente.
    function setSource(address source, string calldata name, bool active) external onlyOwner {
        if (bytes(sources[source].name).length == 0) sourceList.push(source);
        sources[source] = Source(active, name);
        emit SourceSet(source, name, active);
    }

    /// @notice Fija las shares de un beneficiario. Cristaliza lo pendiente antes de cambiar.
    /// @dev Si no cristalizáramos, cambiar shares cambiaría retroactivamente lo ganado.
    function setShares(address b, uint256 newShares) external onlyOwner {
        for (uint256 i; i < tokenList.length; ++i) {
            address t = tokenList[i];
            credited[t][b] += _accrued(t, b);
        }
        if (shares[b] == 0 && newShares > 0 && !_isBeneficiary(b)) beneficiaries.push(b);
        totalShares = totalShares - shares[b] + newShares;
        shares[b] = newShares;
        for (uint256 i; i < tokenList.length; ++i) {
            address t = tokenList[i];
            debt[t][b] = (newShares * accPerShare[t]) / PRECISION;
        }
        emit SharesSet(b, newShares);
    }

    // ------------------------------------------------------------------
    // Registro de ingresos
    // ------------------------------------------------------------------

    /// @notice Una fuente reporta una comisión en ERC20 (transfiere los tokens acá).
    /// @dev Medimos el balance antes/después para soportar tokens con fee-on-transfer:
    ///      se registra lo que REALMENTE llegó, no lo declarado.
    function recordFee(address token, uint256 amount) external nonReentrant {
        if (!sources[msg.sender].active) revert NotSource();
        if (token == ETH || amount == 0) revert BadAmount();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        _book(msg.sender, token, received);
    }

    /// @notice Una fuente reporta una comisión en ETH.
    function recordFeeETH() external payable nonReentrant {
        if (!sources[msg.sender].active) revert NotSource();
        if (msg.value == 0) revert BadAmount();
        _book(msg.sender, ETH, msg.value);
    }

    /// @dev Contabiliza: totales, serie diaria y acumulador de reparto.
    function _book(address source, address token, uint256 amount) internal {
        if (totalShares == 0) revert NoShares(); // sin beneficiarios los fondos quedarían huérfanos
        if (!isTrackedToken[token]) {
            isTrackedToken[token] = true;
            tokenList.push(token);
        }
        uint256 day = block.timestamp / EPOCH;
        totalRevenue[token] += amount;
        revenueBySource[source][token] += amount;
        dailyRevenue[token][day] += amount;
        accPerShare[token] += (amount * PRECISION) / totalShares;
        emit FeeRecorded(source, token, amount, day);
    }

    // ------------------------------------------------------------------
    // Reclamo
    // ------------------------------------------------------------------

    /// @notice El beneficiario retira lo que le corresponde de `token`.
    function claim(address token) external nonReentrant returns (uint256 amount) {
        amount = pending(token, msg.sender);
        credited[token][msg.sender] = 0;
        debt[token][msg.sender] = (shares[msg.sender] * accPerShare[token]) / PRECISION;
        if (amount == 0) return 0;
        if (token == ETH) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit Claimed(msg.sender, token, amount);
    }

    // ------------------------------------------------------------------
    // Lectura (para dashboards)
    // ------------------------------------------------------------------

    /// @notice Lo que `b` puede reclamar ahora de `token`.
    function pending(address token, address b) public view returns (uint256) {
        return credited[token][b] + _accrued(token, b);
    }

    /// @notice Serie diaria de los últimos `days` días (índice 0 = hoy).
    function revenueSeries(address token, uint256 days_) external view returns (uint256[] memory out) {
        out = new uint256[](days_);
        uint256 today = block.timestamp / EPOCH;
        for (uint256 i; i < days_ && i <= today; ++i) {
            out[i] = dailyRevenue[token][today - i];
        }
    }

    /// @notice Suma de los últimos `days` días (útil para APR: ingresos7d * 365/7 / TVL).
    function revenueLastDays(address token, uint256 days_) external view returns (uint256 sum) {
        uint256 today = block.timestamp / EPOCH;
        for (uint256 i; i < days_ && i <= today; ++i) sum += dailyRevenue[token][today - i];
    }

    /// @notice Desglose por fuente para un token.
    function breakdown(address token) external view returns (address[] memory srcs, uint256[] memory amounts) {
        srcs = sourceList;
        amounts = new uint256[](srcs.length);
        for (uint256 i; i < srcs.length; ++i) amounts[i] = revenueBySource[srcs[i]][token];
    }

    function getTokens() external view returns (address[] memory) { return tokenList; }
    function getSources() external view returns (address[] memory) { return sourceList; }

    // ------------------------------------------------------------------
    // Internas
    // ------------------------------------------------------------------

    function _accrued(address token, address b) internal view returns (uint256) {
        return (shares[b] * accPerShare[token]) / PRECISION - debt[token][b];
    }

    function _isBeneficiary(address b) internal view returns (bool) {
        for (uint256 i; i < beneficiaries.length; ++i) if (beneficiaries[i] == b) return true;
        return false;
    }
}
