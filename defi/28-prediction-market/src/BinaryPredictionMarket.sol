// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BinaryPredictionMarket — mercado SÍ/NO con "sets completos" + FPMM y resolución disputable
/// @notice Inspirado en Gnosis Conditional Tokens + FPMM (Omen) y en el flujo optimista de UMA (Polymarket).
///
/// **Tokens de resultado** (ERC-1155, id 0 = YES, id 1 = NO). 1 YES + 1 NO = 1 USDC siempre:
///   - `split(x)`: depositás x USDC → recibís x YES y x NO.
///   - `merge(x)`: devolvés x YES + x NO → recuperás x USDC.
///   Por eso el precio de YES + el de NO ≈ 1 y **el precio de YES es la probabilidad implícita**.
///
/// **FPMM (Fixed Product Market Maker)**: el pool guarda reservas y·n con y·n = k.
///   - comprar YES con x USDC: se hace split de x (y += x, n += x) y se entrega la cantidad de
///     YES que deja el producto constante. P(YES) = n / (y + n).
///   - vender YES por r USDC: el pool retira r sets (y −= r, n −= r → merge → USDC) y el usuario
///     pone los YES que hagan falta para mantener k.
///   - fee para los LPs (acumulador por share).
///
/// **Resolución optimista**: el `resolver` propone un resultado con un bond; durante
/// `disputeWindow` cualquiera puede disputar poniendo el mismo bond; si hay disputa decide el
/// `arbitrator` y el que tenía razón se lleva los dos bonds. Resultado INVALID paga 0,5 a cada lado.
contract BinaryPredictionMarket is ERC1155Supply, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant YES = 0;
    uint256 public constant NO = 1;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    enum Outcome {
        Unresolved,
        Yes,
        No,
        Invalid
    }

    enum Phase {
        Open, // operando
        Closed, // pasó closeTime, esperando propuesta
        Proposed, // propuesta en ventana de disputa
        Disputed, // esperando al árbitro
        Final // resuelto
    }

    IERC20 public immutable collateral;
    string public question;
    uint64 public immutable closeTime;
    address public immutable resolver;
    address public immutable arbitrator;
    uint256 public immutable bond;
    uint256 public immutable disputeWindow;
    uint256 public immutable feeBps;

    // ---------------- FPMM ----------------
    uint256 public reserveYes;
    uint256 public reserveNo;
    mapping(address => uint256) public lpShares;
    uint256 public totalLpShares;
    uint256 public feePerShare; // WAD
    mapping(address => uint256) internal _feeDebt;
    uint256 public unclaimedFees;

    // ------------- Resolución -------------
    Outcome public proposed;
    Outcome public finalOutcome;
    uint64 public proposedAt;
    address public disputer;
    bool public disputed;

    event Split(address indexed user, uint256 amount);
    event Merged(address indexed user, uint256 amount);
    event Bought(address indexed user, uint256 outcome, uint256 investment, uint256 tokensOut, uint256 fee);
    event Sold(address indexed user, uint256 outcome, uint256 returnAmount, uint256 tokensIn, uint256 fee);
    event LiquidityAdded(address indexed lp, uint256 amount, uint256 shares);
    event LiquidityRemoved(address indexed lp, uint256 shares, uint256 yesOut, uint256 noOut, uint256 fees);
    event Proposed(Outcome outcome);
    event Disputed(address indexed disputer);
    event Finalized(Outcome outcome);
    event Redeemed(address indexed user, uint256 payout);

    error WrongPhase(Phase phase);
    error OnlyResolver();
    error OnlyArbitrator();
    error BadOutcome();
    error Slippage();
    error ZeroAmount();
    error NoLiquidity();
    error BadProbability();

    constructor(
        IERC20 collateral_,
        string memory question_,
        uint64 closeTime_,
        address resolver_,
        address arbitrator_,
        uint256 bond_,
        uint256 disputeWindow_,
        uint256 feeBps_
    ) ERC1155("") {
        require(closeTime_ > block.timestamp && feeBps_ < 1_000, "params");
        collateral = collateral_;
        question = question_;
        closeTime = closeTime_;
        resolver = resolver_;
        arbitrator = arbitrator_;
        bond = bond_;
        disputeWindow = disputeWindow_;
        feeBps = feeBps_;
    }

    // =====================================================================
    // Fase
    // =====================================================================

    function phase() public view returns (Phase) {
        if (finalOutcome != Outcome.Unresolved) return Phase.Final;
        if (disputed) return Phase.Disputed;
        if (proposed != Outcome.Unresolved) return Phase.Proposed;
        if (block.timestamp >= closeTime) return Phase.Closed;
        return Phase.Open;
    }

    modifier inPhase(Phase p) {
        Phase cur = phase();
        if (cur != p) revert WrongPhase(cur);
        _;
    }

    // =====================================================================
    // Sets completos
    // =====================================================================

    function split(uint256 amount) external nonReentrant inPhase(Phase.Open) {
        if (amount == 0) revert ZeroAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, YES, amount, "");
        _mint(msg.sender, NO, amount, "");
        emit Split(msg.sender, amount);
    }

    /// @notice Merge permitido hasta la resolución (1 YES + 1 NO vale 1 en cualquier escenario).
    function merge(uint256 amount) external nonReentrant {
        if (phase() == Phase.Final) revert WrongPhase(Phase.Final);
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, YES, amount);
        _burn(msg.sender, NO, amount);
        collateral.safeTransfer(msg.sender, amount);
        emit Merged(msg.sender, amount);
    }

    // =====================================================================
    // FPMM: precios = probabilidades
    // =====================================================================

    /// @notice Probabilidad implícita de YES en WAD: n / (y + n).
    function priceYes() public view returns (uint256) {
        uint256 t = reserveYes + reserveNo;
        if (t == 0) return WAD / 2;
        return Math.mulDiv(reserveNo, WAD, t);
    }

    function priceNo() external view returns (uint256) {
        return WAD - priceYes();
    }

    /// @notice Cuántos tokens `outcome` recibe quien invierte `investment` USDC.
    function calcBuy(uint256 outcome, uint256 investment) public view returns (uint256 out, uint256 fee) {
        if (outcome > 1) revert BadOutcome();
        fee = investment * feeBps / BPS;
        uint256 x = investment - fee;
        (uint256 rBuy, uint256 rOther) = outcome == YES ? (reserveYes, reserveNo) : (reserveNo, reserveYes);
        if (rBuy == 0) revert NoLiquidity();
        uint256 k = rBuy * rOther;
        uint256 newBuy = Math.ceilDiv(k, rOther + x); // redondeo a favor del pool
        out = rBuy + x - newBuy;
    }

    /// @notice Cuántos tokens `outcome` hay que entregar para recibir `returnAmount` USDC.
    function calcSell(uint256 outcome, uint256 returnAmount) public view returns (uint256 tokensIn, uint256 fee) {
        if (outcome > 1) revert BadOutcome();
        uint256 gross = Math.mulDiv(returnAmount, BPS, BPS - feeBps, Math.Rounding.Ceil);
        fee = gross - returnAmount;
        (uint256 rSell, uint256 rOther) = outcome == YES ? (reserveYes, reserveNo) : (reserveNo, reserveYes);
        if (gross >= rOther) revert NoLiquidity();
        uint256 k = rSell * rOther;
        uint256 newSell = Math.ceilDiv(k, rOther - gross);
        tokensIn = newSell + gross - rSell;
    }

    function buy(uint256 outcome, uint256 investment, uint256 minOut)
        external
        nonReentrant
        inPhase(Phase.Open)
        returns (uint256 out)
    {
        if (investment == 0) revert ZeroAmount();
        uint256 fee;
        (out, fee) = calcBuy(outcome, investment);
        if (out < minOut) revert Slippage();
        collateral.safeTransferFrom(msg.sender, address(this), investment);
        _accrueFee(fee);
        uint256 x = investment - fee;
        // split de x: ambas reservas suben x; luego sale `out` del lado comprado
        if (outcome == YES) {
            reserveYes = reserveYes + x - out;
            reserveNo += x;
        } else {
            reserveNo = reserveNo + x - out;
            reserveYes += x;
        }
        _mint(msg.sender, outcome, out, "");
        emit Bought(msg.sender, outcome, investment, out, fee);
    }

    function sell(uint256 outcome, uint256 returnAmount, uint256 maxTokensIn)
        external
        nonReentrant
        inPhase(Phase.Open)
        returns (uint256 tokensIn)
    {
        if (returnAmount == 0) revert ZeroAmount();
        uint256 fee;
        (tokensIn, fee) = calcSell(outcome, returnAmount);
        if (tokensIn > maxTokensIn) revert Slippage();
        _burn(msg.sender, outcome, tokensIn);
        uint256 gross = returnAmount + fee;
        // entran tokensIn del lado vendido y el pool hace merge de `gross` sets
        if (outcome == YES) {
            reserveYes = reserveYes + tokensIn - gross;
            reserveNo -= gross;
        } else {
            reserveNo = reserveNo + tokensIn - gross;
            reserveYes -= gross;
        }
        _accrueFee(fee);
        collateral.safeTransfer(msg.sender, returnAmount);
        emit Sold(msg.sender, outcome, returnAmount, tokensIn, fee);
    }

    // =====================================================================
    // Liquidez
    // =====================================================================

    /// @notice El primer LP fija la probabilidad inicial (`yesProb`, WAD). Los siguientes
    ///         agregan en la proporción actual y reciben de vuelta los tokens sobrantes.
    function addLiquidity(uint256 amount, uint256 yesProb) external nonReentrant inPhase(Phase.Open) returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        _claimFees(msg.sender);

        uint256 addY;
        uint256 addN;
        if (totalLpShares == 0) {
            if (yesProb == 0 || yesProb >= WAD) revert BadProbability();
            // P(YES) = n/(y+n) = p → con la reserva mayor = amount
            if (yesProb >= WAD / 2) {
                addN = amount;
                addY = Math.mulDiv(amount, WAD - yesProb, yesProb);
            } else {
                addY = amount;
                addN = Math.mulDiv(amount, yesProb, WAD - yesProb);
            }
            shares = amount;
        } else {
            uint256 m = Math.max(reserveYes, reserveNo);
            addY = Math.mulDiv(amount, reserveYes, m);
            addN = Math.mulDiv(amount, reserveNo, m);
            shares = Math.mulDiv(amount, totalLpShares, m);
        }
        reserveYes += addY;
        reserveNo += addN;
        // el LP hizo split de `amount`; lo que no entró al pool se le devuelve en tokens
        if (amount > addY) _mint(msg.sender, YES, amount - addY, "");
        if (amount > addN) _mint(msg.sender, NO, amount - addN, "");

        lpShares[msg.sender] += shares;
        totalLpShares += shares;
        _feeDebt[msg.sender] = Math.mulDiv(lpShares[msg.sender], feePerShare, WAD);
        emit LiquidityAdded(msg.sender, amount, shares);
    }

    /// @notice Retira la parte proporcional de las reservas (en tokens) + fees acumuladas.
    ///         Permitido en cualquier fase: tras la resolución el LP canjea los tokens.
    function removeLiquidity(uint256 shares) external nonReentrant returns (uint256 yOut, uint256 nOut) {
        if (shares == 0) revert ZeroAmount();
        uint256 fees = _claimFees(msg.sender);
        yOut = Math.mulDiv(reserveYes, shares, totalLpShares);
        nOut = Math.mulDiv(reserveNo, shares, totalLpShares);
        lpShares[msg.sender] -= shares;
        totalLpShares -= shares;
        reserveYes -= yOut;
        reserveNo -= nOut;
        _feeDebt[msg.sender] = Math.mulDiv(lpShares[msg.sender], feePerShare, WAD);
        _mint(msg.sender, YES, yOut, "");
        _mint(msg.sender, NO, nOut, "");
        emit LiquidityRemoved(msg.sender, shares, yOut, nOut, fees);
    }

    function pendingFees(address lp) public view returns (uint256) {
        return Math.mulDiv(lpShares[lp], feePerShare, WAD) - _feeDebt[lp];
    }

    function _accrueFee(uint256 fee) internal {
        if (fee == 0 || totalLpShares == 0) return;
        feePerShare += Math.mulDiv(fee, WAD, totalLpShares);
        unclaimedFees += fee;
    }

    function _claimFees(address lp) internal returns (uint256 f) {
        f = pendingFees(lp);
        if (f > unclaimedFees) f = unclaimedFees; // polvo de redondeo
        if (f > 0) {
            unclaimedFees -= f;
            collateral.safeTransfer(lp, f);
        }
        _feeDebt[lp] = Math.mulDiv(lpShares[lp], feePerShare, WAD);
    }

    // =====================================================================
    // Resolución optimista
    // =====================================================================

    function propose(Outcome outcome) external nonReentrant inPhase(Phase.Closed) {
        if (msg.sender != resolver) revert OnlyResolver();
        if (outcome == Outcome.Unresolved) revert BadOutcome();
        collateral.safeTransferFrom(msg.sender, address(this), bond);
        proposed = outcome;
        proposedAt = uint64(block.timestamp);
        emit Proposed(outcome);
    }

    function dispute() external nonReentrant inPhase(Phase.Proposed) {
        if (block.timestamp >= proposedAt + disputeWindow) revert WrongPhase(Phase.Proposed);
        collateral.safeTransferFrom(msg.sender, address(this), bond);
        disputed = true;
        disputer = msg.sender;
        emit Disputed(msg.sender);
    }

    /// @notice Sin disputa y pasada la ventana, cualquiera finaliza; el resolver recupera su bond.
    function finalize() external nonReentrant inPhase(Phase.Proposed) {
        if (block.timestamp < proposedAt + disputeWindow) revert WrongPhase(Phase.Proposed);
        finalOutcome = proposed;
        collateral.safeTransfer(resolver, bond);
        emit Finalized(finalOutcome);
    }

    /// @notice El árbitro decide; quien tenía razón se lleva ambos bonds.
    function arbitrate(Outcome outcome) external nonReentrant inPhase(Phase.Disputed) {
        if (msg.sender != arbitrator) revert OnlyArbitrator();
        if (outcome == Outcome.Unresolved) revert BadOutcome();
        finalOutcome = outcome;
        collateral.safeTransfer(outcome == proposed ? resolver : disputer, 2 * bond);
        emit Finalized(outcome);
    }

    /// @notice Canjea todos los tokens del usuario según el resultado final.
    function redeem() external nonReentrant inPhase(Phase.Final) returns (uint256 payout) {
        uint256 y = balanceOf(msg.sender, YES);
        uint256 n = balanceOf(msg.sender, NO);
        if (y > 0) _burn(msg.sender, YES, y);
        if (n > 0) _burn(msg.sender, NO, n);
        if (finalOutcome == Outcome.Yes) payout = y;
        else if (finalOutcome == Outcome.No) payout = n;
        else payout = (y + n) / 2; // INVALID
        if (payout > 0) collateral.safeTransfer(msg.sender, payout);
        emit Redeemed(msg.sender, payout);
    }
}
