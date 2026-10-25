// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SelfMulticall — permite a un contrato agrupar llamadas a sí mismo (delegatecall)
/// @notice A diferencia de Multicall, acá `msg.sender` se preserva (es el usuario), porque
///         usamos delegatecall a `address(this)`. Es el patrón de los routers de Uniswap V3.
/// @dev SEGURIDAD: la función NO es `payable`. Si lo fuera, `msg.value` se "reutilizaría" en
///      cada sub-llamada (todas ven el mismo msg.value) y un usuario podría acreditar N veces
///      un único depósito (bug real de varios protocolos). El test lo demuestra con una
///      versión vulnerable.
abstract contract SelfMulticall {
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i < data.length;) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            if (!ok) {
                // Re-lanza el error original tal cual
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            results[i] = ret;
            unchecked {
                ++i;
            }
        }
    }
}
