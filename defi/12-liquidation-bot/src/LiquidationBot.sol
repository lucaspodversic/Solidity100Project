// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {LendingPool} from "./protocol/LendingPool.sol";
import {PriceOracle} from "./protocol/PriceOracle.sol";
import {OracleDex} from "./mocks/OracleDex.sol";

/// @title LiquidationBot — liquidador con capital cero vía flash loan
/// @notice Flujo atómico de `execute`:
///         1. Pide un flash loan del activo de deuda (ERC-3156).
///         2. Liquida la posición en el LendingPool y recibe colateral + bonus.
///         3. Vende el colateral en el DEX por el activo de deuda.
///         4. Devuelve préstamo + fee; si la ganancia < `minProfit`, revierte todo.
///         5. Envía la ganancia al owner.
///         Además expone `scan`, una vista que el bot off-chain (o el script) usa para
///         encontrar posiciones liquidables y estimar su rentabilidad.
/// @dev Seguridad del callback: sólo acepta llamadas del flash lender configurado y con
///      `initiator == address(this)`; así nadie puede disparar el callback para usar los
///      approvals del bot ni ejecutar liquidaciones con parámetros arbitrarios.
contract LiquidationBot is IERC3156FlashBorrower, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 internal constant WAD = 1e18;

    LendingPool public immutable pool;
    IERC3156FlashLender public immutable lender;
    OracleDex public immutable dex;

    struct Params {
        address user;
        address debtAsset;
        address collateralAsset;
        uint256 repayAmount;
        uint256 minProfit; // en unidades del activo de deuda
    }

    struct Opportunity {
        address user;
        uint256 healthFactor;
        uint256 repayAmount; // deuda a repagar (activo de deuda)
        uint256 expectedSeized; // colateral esperado
        int256 estProfit; // ganancia estimada en activo de deuda (puede ser negativa)
    }

    event Liquidated(address indexed user, uint256 repaid, uint256 seized);
    event ProfitTaken(address indexed token, uint256 profit);

    error UntrustedLender();
    error UntrustedInitiator();
    error NotProfitable(uint256 profit, uint256 minProfit);

    constructor(LendingPool _pool, IERC3156FlashLender _lender, OracleDex _dex) Ownable(msg.sender) {
        pool = _pool;
        lender = _lender;
        dex = _dex;
    }

    // ------------------------------------------------------------------
    // Ejecución
    // ------------------------------------------------------------------

    /// @notice Ejecuta una liquidación atómica. Sólo el owner (evita que terceros usen el bot
    ///         como "oráculo de rentabilidad" o le hagan perder el fee del flash loan).
    function execute(Params calldata p) external onlyOwner nonReentrant returns (uint256 profit) {
        uint256 before = IERC20(p.debtAsset).balanceOf(address(this));
        lender.flashLoan(this, p.debtAsset, p.repayAmount, abi.encode(p));
        uint256 afterBal = IERC20(p.debtAsset).balanceOf(address(this));
        profit = afterBal > before ? afterBal - before : 0;
        if (profit < p.minProfit) revert NotProfitable(profit, p.minProfit);
        if (profit > 0) IERC20(p.debtAsset).safeTransfer(owner(), profit);
        emit ProfitTaken(p.debtAsset, profit);
    }

    /// @inheritdoc IERC3156FlashBorrower
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        if (msg.sender != address(lender)) revert UntrustedLender();
        if (initiator != address(this)) revert UntrustedInitiator();
        Params memory p = abi.decode(data, (Params));

        // 2. Liquidación. Approve exacto (no infinito) para limitar la superficie de ataque.
        IERC20(token).forceApprove(address(pool), amount);
        (uint256 repaid, uint256 seized) = pool.liquidate(p.debtAsset, p.collateralAsset, p.user, amount);
        IERC20(token).forceApprove(address(pool), 0);

        // 3. Venta del colateral. minOut = lo necesario para devolver el préstamo; si el DEX no
        //    lo da, revertimos acá (más barato que esperar al chequeo de ganancia).
        uint256 leftover = amount - repaid; // si el colateral no alcanzó, sobró deuda sin usar
        uint256 needed = amount + fee > leftover ? amount + fee - leftover : 0;
        IERC20(p.collateralAsset).forceApprove(address(dex), seized);
        dex.swap(p.collateralAsset, p.debtAsset, seized, needed);

        // 4. Devolución: el lender cobra con transferFrom.
        IERC20(token).forceApprove(address(lender), amount + fee);
        emit Liquidated(p.user, repaid, seized);
        return CALLBACK_SUCCESS;
    }

    /// @notice Rescate de tokens que hayan quedado en el contrato.
    function sweep(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    // ------------------------------------------------------------------
    // Búsqueda de oportunidades (vista)
    // ------------------------------------------------------------------

    /// @notice Evalúa una lista de cuentas para un par deuda/colateral.
    /// @dev Estimación: repago = min(50 % deuda, lo que cubre el colateral);
    ///      ganancia ≈ quoteDEX(colateral incautado) − repago − fee flash.
    ///      Usa índices del último accrue (aproximado; `execute` hace el cálculo exacto).
    function scan(address[] calldata users, address debtAsset, address collAsset)
        external
        view
        returns (Opportunity[] memory ops)
    {
        ops = new Opportunity[](users.length);
        for (uint256 i; i < users.length; i++) {
            ops[i] = _evaluate(users[i], debtAsset, collAsset);
        }
    }

    function _evaluate(address user, address debtAsset, address collAsset)
        internal
        view
        returns (Opportunity memory op)
    {
        op.user = user;
        op.healthFactor = pool.healthFactor(user);
        if (op.healthFactor >= WAD) return op;
        uint256 debt = pool.borrowBalance(debtAsset, user);
        uint256 repay = (debt * pool.CLOSE_FACTOR()) / WAD;
        uint256 seized = _seizeFor(repay, debtAsset, collAsset);
        uint256 available = pool.supplyBalance(collAsset, user);
        if (seized > available) {
            repay = (repay * available) / seized;
            seized = available;
        }
        op.repayAmount = repay;
        op.expectedSeized = seized;
        if (seized == 0) return op;
        uint256 out = dex.quote(collAsset, debtAsset, seized);
        uint256 cost = repay + lender.flashFee(debtAsset, repay);
        op.estProfit = int256(out) - int256(cost);
    }

    function _seizeFor(uint256 repay, address debtAsset, address collAsset) internal view returns (uint256) {
        PriceOracle o = pool.oracle();
        (,,,,, uint256 bonus,,,,,,,) = pool.markets(collAsset);
        uint256 usd = (repay * o.getPrice(debtAsset)) / 10 ** IERC20Metadata(debtAsset).decimals();
        usd = (usd * (WAD + bonus)) / WAD;
        return (usd * 10 ** IERC20Metadata(collAsset).decimals()) / o.getPrice(collAsset);
    }
}
