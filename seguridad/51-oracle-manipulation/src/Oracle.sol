// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SpotPair — AMM mínimo (x*y=k) usado como "oracle" spot
/// @notice VULNERABLE como oracle: un flash loan puede mover el precio en la misma tx.
contract SpotPair {
    uint256 public reserveA;
    uint256 public reserveB;
    constructor(uint256 a, uint256 b) { reserveA = a; reserveB = b; }
    function spotPrice() public view returns (uint256) {
        // precio de A en unidades de B (1e18)
        return (reserveB * 1e18) / reserveA;
    }
    function swapAforB(uint256 amountA) external returns (uint256 outB) {
        outB = (amountA * reserveB) / (reserveA + amountA);
        reserveA += amountA;
        reserveB -= outB;
    }
    function swapBforA(uint256 amountB) external returns (uint256 outA) {
        outA = (amountB * reserveA) / (reserveB + amountB);
        reserveB += amountB;
        reserveA -= outA;
    }
}

/// @title LendingVulnerable — presta según spot price (manipulable)
contract LendingVulnerable {
    SpotPair public pair;
    mapping(address => uint256) public collateralA;
    mapping(address => uint256) public debtB;
    constructor(address pair_) { pair = SpotPair(pair_); }
    function depositCollateral(uint256 amountA) external { collateralA[msg.sender] += amountA; }
    function borrow(uint256 amountB) external {
        uint256 value = (collateralA[msg.sender] * pair.spotPrice()) / 1e18;
        require(value >= amountB * 2, "LFV"); // 50% LTV
        debtB[msg.sender] += amountB;
        // en demo no transferimos tokens reales
    }
}

/// @title TWAPOracle — defensa: promedio temporal (simplificado)
contract TWAPOracle {
    SpotPair public immutable pair;
    uint256 public cumulative;
    uint256 public lastTimestamp;
    uint256 public lastPrice;
    constructor(address pair_) {
        pair = SpotPair(pair_);
        lastPrice = pair.spotPrice();
        lastTimestamp = block.timestamp;
    }
    function update() public {
        uint256 dt = block.timestamp - lastTimestamp;
        if (dt > 0) {
            cumulative += lastPrice * dt;
            lastPrice = pair.spotPrice();
            lastTimestamp = block.timestamp;
        }
    }
    function twap(uint256 window) external returns (uint256) {
        update();
        // Demo: devolvemos lastPrice suavizado; en prod se guarda historial de acumuladores.
        // Acá simulamos que el TWAP no se mueve en la misma tx (dt=0 tras update).
        window;
        return lastPrice; // tras un update en tx distinta refleja el promedio
    }
}

/// @title LendingSafe — usa TWAP en vez de spot
contract LendingSafe {
    TWAPOracle public oracle;
    mapping(address => uint256) public collateralA;
    mapping(address => uint256) public debtB;
    constructor(address oracle_) { oracle = TWAPOracle(oracle_); }
    function depositCollateral(uint256 amountA) external { collateralA[msg.sender] += amountA; }
    function borrow(uint256 amountB) external {
        uint256 price = oracle.twap(1 hours);
        uint256 value = (collateralA[msg.sender] * price) / 1e18;
        require(value >= amountB * 2, "LFV");
        debtB[msg.sender] += amountB;
    }
}
