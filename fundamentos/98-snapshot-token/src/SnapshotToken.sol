// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SnapshotToken — ERC20 con instantáneas de saldos para gobernanza
/// @author Proyecto "100 proyectos Solidity" — Lote D (Fundamentos), #98
/// @notice El owner toma un `snapshot()` (p. ej. al crear una propuesta) y
///         luego cualquiera consulta `balanceOfAt(cuenta, id)` y
///         `totalSupplyAt(id)`: los saldos "congelados" en ese momento.
///         Así nadie puede votar, transferir y volver a votar con los mismos
///         tokens (ataque de doble voto / flash loans de gobernanza).
/// @dev Re-implementación didáctica del `ERC20Snapshot` de OZ v4 (eliminado
///      en v5 en favor de `ERC20Votes`, que usa checkpoints por bloque/tiempo).
///      Algoritmo "lazy" (perezoso):
///   - Tomar un snapshot es O(1): solo incrementa `_currentSnapshotId`.
///   - Recién cuando un saldo VA A CAMBIAR, guardamos su valor previo
///     etiquetado con el id actual (si no se guardó ya para ese id).
///   - Para consultar el id `n`, buscamos (búsqueda binaria) el primer
///     registro con id ≥ n: ese valor era el saldo en el snapshot `n`.
///     Si no hay ninguno, el saldo no cambió desde entonces => saldo actual.
contract SnapshotToken is ERC20, Ownable {
    error NonexistentSnapshot(uint256 id);

    event Snapshot(uint256 id);

    /// @dev Historial: ids de snapshot y valores asociados (arrays paralelos).
    struct Snapshots {
        uint256[] ids;
        uint256[] values;
    }

    mapping(address => Snapshots) private _accountSnapshots;
    Snapshots private _totalSupplySnapshots;
    /// @dev Id del último snapshot (0 = ninguno todavía).
    uint256 private _currentSnapshotId;

    constructor(uint256 initialSupply) ERC20("Snapshot Governance", "SNAP") Ownable(msg.sender) {
        _mint(msg.sender, initialSupply);
    }

    /// @notice Tomar una instantánea. Devuelve su id.
    /// @dev Restringido al owner: si fuese público, un atacante podría crear
    ///      miles de snapshots para encarecer las transferencias de todos.
    function snapshot() external onlyOwner returns (uint256 id) {
        id = ++_currentSnapshotId;
        emit Snapshot(id);
    }

    function currentSnapshotId() external view returns (uint256) {
        return _currentSnapshotId;
    }

    /// @notice Saldo de `account` en el snapshot `id`.
    function balanceOfAt(address account, uint256 id) public view returns (uint256) {
        (bool found, uint256 v) = _valueAt(id, _accountSnapshots[account]);
        return found ? v : balanceOf(account);
    }

    /// @notice Suministro total en el snapshot `id`.
    function totalSupplyAt(uint256 id) public view returns (uint256) {
        (bool found, uint256 v) = _valueAt(id, _totalSupplySnapshots);
        return found ? v : totalSupply();
    }

    /// @dev Hook de OZ v5: se ejecuta en toda transferencia/mint/burn.
    ///      Guardamos los valores PREVIOS antes de que cambien.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            // mint: cambia el saldo de `to` y el supply
            _updateSnapshot(_accountSnapshots[to], balanceOf(to));
            _updateSnapshot(_totalSupplySnapshots, totalSupply());
        } else if (to == address(0)) {
            // burn: cambia el saldo de `from` y el supply
            _updateSnapshot(_accountSnapshots[from], balanceOf(from));
            _updateSnapshot(_totalSupplySnapshots, totalSupply());
        } else {
            // transferencia: cambian ambos saldos
            _updateSnapshot(_accountSnapshots[from], balanceOf(from));
            _updateSnapshot(_accountSnapshots[to], balanceOf(to));
        }
        super._update(from, to, value);
    }

    /// @dev Busca el valor registrado para el snapshot `id`.
    function _valueAt(uint256 id, Snapshots storage s) private view returns (bool, uint256) {
        if (id == 0 || id > _currentSnapshotId) revert NonexistentSnapshot(id);
        uint256 idx = _upperBound(s.ids, id);
        if (idx == s.ids.length) return (false, 0);
        return (true, s.values[idx]);
    }

    /// @dev Registra `currentValue` para el snapshot actual si aún no se hizo.
    function _updateSnapshot(Snapshots storage s, uint256 currentValue) private {
        uint256 cur = _currentSnapshotId;
        if (cur == 0) return; // sin snapshots, no hay nada que preservar
        uint256 len = s.ids.length;
        if (len == 0 || s.ids[len - 1] < cur) {
            s.ids.push(cur);
            s.values.push(currentValue);
        }
    }

    /// @dev Búsqueda binaria: primer índice con `arr[i] >= x` (o length).
    ///      O(log n): el costo de consulta crece muy lento con el historial.
    function _upperBound(uint256[] storage arr, uint256 x) private view returns (uint256) {
        uint256 low = 0;
        uint256 high = arr.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (arr[mid] < x) low = mid + 1;
            else high = mid;
        }
        return low;
    }
}
