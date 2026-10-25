// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DelegatedLendingPool} from "./DelegatedLendingPool.sol";

/// @title CreditAgreement — acuerdos on-chain de delegación de crédito con prima
/// @notice La delegación "pelada" de Aave confía 100 % en el delegado. Este contrato agrega
///         términos explícitos:
///         - el delegador aprueba la delegación A ESTE CONTRATO (no al delegado);
///         - crea un acuerdo: delegado, activo, límite, prima anual (bps) y vencimiento;
///         - el delegado retira con `draw` (el contrato pide prestado on-behalf del delegador);
///         - el delegado repaga con `repay`: el principal va al pool (repago on-behalf) y la
///           PRIMA va directo al delegador como pago por prestar su colateral;
///         - pasado el vencimiento sin repago total, el acuerdo queda en DEFAULT (evento
///           público → reputación on-chain / recurso legal off-chain).
/// @dev La prima es interés simple sobre el principal pendiente. El acuerdo NO rastrea el
///      interés variable del pool sobre la deuda del delegador: la prima debe fijarse por
///      encima de la tasa del pool para que el delegador gane (ver README).
contract CreditAgreement is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant YEAR = 365 days;

    DelegatedLendingPool public immutable pool;

    enum Status {
        None,
        Active,
        Repaid,
        Defaulted,
        Cancelled
    }

    struct Agreement {
        address delegator;
        address delegatee;
        address asset;
        uint256 limit;
        uint256 premiumBps; // anual
        uint64 maturity;
        uint64 lastUpdate;
        uint256 principal; // pendiente
        uint256 premiumAccrued; // pendiente
        uint256 premiumPaid;
        Status status;
    }

    Agreement[] public agreements;

    event AgreementCreated(uint256 indexed id, address indexed delegator, address indexed delegatee, uint256 limit);
    event Drawn(uint256 indexed id, uint256 amount);
    event Repaid(uint256 indexed id, uint256 principal, uint256 premium);
    event Defaulted(uint256 indexed id, uint256 principal, uint256 premium);
    event Cancelled(uint256 indexed id);

    error NotDelegatee();
    error NotDelegator();
    error NotActive();
    error OverLimit();
    error Matured();
    error NotMatured();
    error Outstanding();

    constructor(DelegatedLendingPool _pool) {
        pool = _pool;
    }

    /// @notice El delegador define los términos. Debe haber hecho
    ///         `pool.approveDelegation(asset, address(this), limit)` (o mayor).
    function create(address delegatee, address asset, uint256 limit, uint256 premiumBps, uint64 maturity)
        external
        returns (uint256 id)
    {
        require(maturity > block.timestamp && limit > 0 && premiumBps <= 10_000, "params");
        id = agreements.length;
        agreements.push(
            Agreement(msg.sender, delegatee, asset, limit, premiumBps, maturity, uint64(block.timestamp), 0, 0, 0, Status.Active)
        );
        emit AgreementCreated(id, msg.sender, delegatee, limit);
    }

    /// @notice Prima pendiente a la fecha.
    function premiumDue(uint256 id) public view returns (uint256) {
        Agreement storage a = agreements[id];
        uint256 dt = block.timestamp - a.lastUpdate;
        return a.premiumAccrued + (a.principal * a.premiumBps * dt) / (10_000 * YEAR);
    }

    function _checkpoint(Agreement storage a, uint256 id) internal {
        a.premiumAccrued = premiumDue(id);
        a.lastUpdate = uint64(block.timestamp);
    }

    /// @notice El delegado retira crédito. El pool registra la deuda al delegador.
    function draw(uint256 id, uint256 amount) external nonReentrant {
        Agreement storage a = agreements[id];
        if (msg.sender != a.delegatee) revert NotDelegatee();
        if (a.status != Status.Active) revert NotActive();
        if (block.timestamp >= a.maturity) revert Matured();
        if (a.principal + amount > a.limit) revert OverLimit();
        _checkpoint(a, id);
        a.principal += amount;
        pool.borrowOnBehalf(a.asset, amount, a.delegator);
        IERC20(a.asset).safeTransfer(msg.sender, amount);
        emit Drawn(id, amount);
    }

    /// @notice Repago: primero la prima (al delegador), luego el principal (al pool).
    /// @param amount Monto total que aporta quien paga (cualquiera puede pagar por el delegado).
    function repay(uint256 id, uint256 amount) external nonReentrant {
        Agreement storage a = agreements[id];
        if (a.status != Status.Active && a.status != Status.Defaulted) revert NotActive();
        _checkpoint(a, id);
        uint256 toPremium = amount < a.premiumAccrued ? amount : a.premiumAccrued;
        uint256 toPrincipal = amount - toPremium;
        if (toPrincipal > a.principal) toPrincipal = a.principal;

        IERC20 t = IERC20(a.asset);
        t.safeTransferFrom(msg.sender, address(this), toPremium + toPrincipal);
        if (toPremium > 0) {
            a.premiumAccrued -= toPremium;
            a.premiumPaid += toPremium;
            t.safeTransfer(a.delegator, toPremium);
        }
        if (toPrincipal > 0) {
            a.principal -= toPrincipal;
            t.forceApprove(address(pool), toPrincipal);
            pool.repay(a.asset, toPrincipal, a.delegator);
        }
        if (a.principal == 0 && a.premiumAccrued == 0) a.status = Status.Repaid;
        emit Repaid(id, toPrincipal, toPremium);
    }

    /// @notice Cualquiera puede marcar default tras el vencimiento con saldo pendiente.
    function markDefault(uint256 id) external {
        Agreement storage a = agreements[id];
        if (a.status != Status.Active) revert NotActive();
        if (block.timestamp < a.maturity) revert NotMatured();
        _checkpoint(a, id);
        if (a.principal == 0 && a.premiumAccrued == 0) revert NotActive();
        a.status = Status.Defaulted;
        emit Defaulted(id, a.principal, a.premiumAccrued);
    }

    /// @notice El delegador cancela un acuerdo sin saldo (ya no se puede retirar más).
    function cancel(uint256 id) external {
        Agreement storage a = agreements[id];
        if (msg.sender != a.delegator) revert NotDelegator();
        if (a.status != Status.Active) revert NotActive();
        if (a.principal != 0) revert Outstanding();
        a.status = Status.Cancelled;
        emit Cancelled(id);
    }

    function count() external view returns (uint256) {
        return agreements.length;
    }
}
