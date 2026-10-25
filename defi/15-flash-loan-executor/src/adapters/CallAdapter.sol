// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "./IAdapter.sol";

/// @title CallAdapter — llamada genérica con approve previo (escape hatch)
/// @notice data = abi.encode(CallParams{target, approveToken, approveAmount, callData, returnsUint}).
///         Aprueba `approveAmount` (o `prev` si es max) a `target`, llama, y luego resetea el
///         approve a 0. Si `returnsUint`, decodifica el retorno como uint256 de salida.
/// @dev Potente y peligroso: sólo el owner arma los pasos, y el approve se limpia siempre.
contract CallAdapter is IAdapter {
    using SafeERC20 for IERC20;

    error CallFailed(bytes reason);

    struct CallParams {
        address target;
        address approveToken;
        uint256 approveAmount;
        bytes callData;
        bool returnsUint;
    }

    function execute(bytes calldata data, uint256 prev) external payable returns (uint256 out) {
        CallParams memory p = abi.decode(data, (CallParams));
        if (p.approveToken != address(0)) {
            IERC20(p.approveToken).forceApprove(p.target, p.approveAmount == type(uint256).max ? prev : p.approveAmount);
        }
        (bool ok, bytes memory ret) = p.target.call(p.callData);
        if (!ok) revert CallFailed(ret);
        if (p.approveToken != address(0)) IERC20(p.approveToken).forceApprove(p.target, 0);
        out = p.returnsUint ? abi.decode(ret, (uint256)) : prev;
    }
}
