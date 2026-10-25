// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IAdapter} from "./adapters/IAdapter.sol";

/// @title FlashLoanExecutor — ejecutor modular de operaciones encadenadas con flash loans
/// @notice El owner arma una "receta": lista de pasos `(adapter, data)`. El executor:
///         1. pide un flash loan (ERC-3156) de `token`/`amount`;
///         2. ejecuta cada paso vía DELEGATECALL a un adapter WHITELISTEADO, pasando la
///            salida del paso anterior (`prev`) para encadenar montos;
///         3. aprueba el repago (amount + fee);
///         4. verifica que la ganancia en `token` ≥ `minProfit` y la envía al owner.
///         También permite `runWithoutLoan` (misma receta, sin flash loan) para composición.
/// @dev Modelo de seguridad:
///      - Sólo el owner inicia (`onlyOwner`), y `onFlashLoan` exige lender confiable,
///        `initiator == this` y una bandera `_executing` activa (doble candado).
///      - Los adapters corren con delegatecall: tienen todo el poder del executor. Por eso
///        sólo los aprueba el owner y deben ser stateless (ver IAdapter).
///      - `_executing` está en storage en el slot propio; los adapters no usan storage.
contract FlashLoanExecutor is IERC3156FlashBorrower, Ownable {
    using SafeERC20 for IERC20;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    struct Step {
        address adapter;
        bytes data;
    }

    mapping(address => bool) public isAdapter;
    mapping(address => bool) public isLender;
    bool private _executing;

    event AdapterSet(address indexed adapter, bool allowed);
    event LenderSet(address indexed lender, bool allowed);
    event RecipeExecuted(address indexed token, uint256 amount, uint256 fee, uint256 profit, uint256 steps);

    error AdapterNotAllowed(address adapter);
    error UntrustedLender();
    error UntrustedInitiator();
    error NotExecuting();
    error Reentrant();
    error StepFailed(uint256 index, bytes reason);
    error InsufficientProfit(uint256 profit, uint256 minProfit);

    constructor() Ownable(msg.sender) {}

    function setAdapter(address adapter, bool allowed) external onlyOwner {
        isAdapter[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    function setLender(address lender, bool allowed) external onlyOwner {
        isLender[lender] = allowed;
        emit LenderSet(lender, allowed);
    }

    /// @notice Ejecuta una receta financiada con flash loan.
    function run(IERC3156FlashLender lender, address token, uint256 amount, Step[] calldata steps, uint256 minProfit)
        external
        onlyOwner
        returns (uint256 profit)
    {
        if (!isLender[address(lender)]) revert UntrustedLender();
        if (_executing) revert Reentrant();
        _executing = true;
        uint256 before = IERC20(token).balanceOf(address(this));
        lender.flashLoan(this, token, amount, abi.encode(steps));
        _executing = false;
        profit = _settle(token, before, minProfit);
        emit RecipeExecuted(token, amount, lender.flashFee(token, amount), profit, steps.length);
    }

    /// @notice Ejecuta una receta con fondos propios del executor (sin préstamo).
    function runWithoutLoan(address token, uint256 startAmount, Step[] calldata steps, uint256 minProfit)
        external
        payable
        onlyOwner
        returns (uint256 profit)
    {
        if (_executing) revert Reentrant();
        _executing = true;
        uint256 before = IERC20(token).balanceOf(address(this));
        _runSteps(steps, startAmount);
        _executing = false;
        profit = _settle(token, before, minProfit);
        emit RecipeExecuted(token, 0, 0, profit, steps.length);
    }

    /// @inheritdoc IERC3156FlashBorrower
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        if (!isLender[msg.sender]) revert UntrustedLender();
        if (initiator != address(this)) revert UntrustedInitiator();
        if (!_executing) revert NotExecuting();
        Step[] memory steps = abi.decode(data, (Step[]));
        _runStepsMem(steps, amount);
        IERC20(token).forceApprove(msg.sender, amount + fee);
        return CALLBACK_SUCCESS;
    }

    function _runSteps(Step[] calldata steps, uint256 prev) internal {
        for (uint256 i; i < steps.length; i++) {
            prev = _step(i, steps[i].adapter, steps[i].data, prev);
        }
    }

    function _runStepsMem(Step[] memory steps, uint256 prev) internal {
        for (uint256 i; i < steps.length; i++) {
            prev = _step(i, steps[i].adapter, steps[i].data, prev);
        }
    }

    /// @dev Delegatecall al adapter; burbujea el motivo del revert envuelto en StepFailed.
    function _step(uint256 i, address adapter, bytes memory data, uint256 prev) internal returns (uint256) {
        if (!isAdapter[adapter]) revert AdapterNotAllowed(adapter);
        (bool ok, bytes memory ret) = adapter.delegatecall(abi.encodeCall(IAdapter.execute, (data, prev)));
        if (!ok) revert StepFailed(i, ret);
        return abi.decode(ret, (uint256));
    }

    /// @dev Calcula ganancia neta y la transfiere al owner.
    function _settle(address token, uint256 before, uint256 minProfit) internal returns (uint256 profit) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        profit = bal > before ? bal - before : 0;
        if (profit < minProfit) revert InsufficientProfit(profit, minProfit);
        if (profit > 0) IERC20(token).safeTransfer(owner(), profit);
    }

    /// @notice Rescate de tokens o ETH.
    function sweep(address token) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = owner().call{value: address(this).balance}("");
            require(ok);
        } else {
            IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
        }
    }

    receive() external payable {}
}
