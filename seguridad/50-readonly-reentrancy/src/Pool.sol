// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title CurveStylePool — vulnerable a read-only reentrancy
/// @author Proyecto 50
/// @notice Al remover liquidez envía ETH y reentra; durante el callback el
///         `getVirtualPrice()` todavía refleja el estado viejo (inflado).
///         Un vault que confía en ese precio puede ser manipulado.
contract CurveStylePool {
    mapping(address => uint256) public lp;
    uint256 public totalLP;
    uint256 public ethReserves;
    bool private locked;

    function addLiquidity() external payable {
        uint256 mint = totalLP == 0 ? msg.value : (msg.value * totalLP) / ethReserves;
        lp[msg.sender] += mint;
        totalLP += mint;
        ethReserves += msg.value;
    }

    /// @notice VULNERABLE: actualiza ethReserves DESPUÉS del call (y sin lock en view).
    function removeLiquidity(uint256 amount) external {
        require(lp[msg.sender] >= amount, "lp");
        uint256 ethOut = (amount * ethReserves) / totalLP;
        lp[msg.sender] -= amount;
        totalLP -= amount;
        // INTERACTION antes de actualizar ethReserves → read-only reentrancy
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "pay");
        ethReserves -= ethOut;
    }

    /// @notice Precio virtual "stale" durante la reentrancy.
    function getVirtualPrice() public view returns (uint256) {
        if (totalLP == 0) return 1e18;
        return (ethReserves * 1e18) / totalLP;
    }
}

/// @title VaultQueConfiaEnElPrecio — víctima de read-only reentrancy
contract PriceVault {
    CurveStylePool public pool;
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    constructor(address pool_) { pool = CurveStylePool(pool_); }
    function deposit() external payable {
        uint256 price = pool.getVirtualPrice();
        uint256 minted = (msg.value * 1e18) / price;
        shares[msg.sender] += minted;
        totalShares += minted;
    }
    function valueOf(address u) external view returns (uint256) {
        return (shares[u] * pool.getVirtualPrice()) / 1e18;
    }
}

/// @title PoolSafe — lock también en views (estilo Curve fix)
contract PoolSafe {
    mapping(address => uint256) public lp;
    uint256 public totalLP;
    uint256 public ethReserves;
    uint256 private locked;
    modifier lock() { require(locked == 0, "locked"); locked = 1; _; locked = 0; }
    function addLiquidity() external payable lock {
        uint256 mint = totalLP == 0 ? msg.value : (msg.value * totalLP) / ethReserves;
        lp[msg.sender] += mint; totalLP += mint; ethReserves += msg.value;
    }
    function removeLiquidity(uint256 amount) external lock {
        require(lp[msg.sender] >= amount, "lp");
        uint256 ethOut = (amount * ethReserves) / totalLP;
        lp[msg.sender] -= amount; totalLP -= amount; ethReserves -= ethOut; // EFFECT primero
        (bool ok,) = msg.sender.call{value: ethOut}(""); require(ok, "pay");
    }
    function getVirtualPrice() public view returns (uint256) {
        require(locked == 0, "reentrancy"); // DEFENSA read-only
        if (totalLP == 0) return 1e18;
        return (ethReserves * 1e18) / totalLP;
    }
}
