// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BadLogic — storage layout INCOMPATIBLE con el proxy
/// @author Proyecto 56
/// @notice El proxy guarda admin en slot 0. BadLogic usa slot 0 para `total`.
///         Un deposit sobrescribe admin → takeover.
contract BadLogic {
    uint256 public total;              // slot 0 ← colisiona con proxy.admin
    mapping(address => uint256) public bal; // slot 1 ← colisiona con proxy.implementation

    function deposit() external payable {
        total += msg.value;
        bal[msg.sender] += msg.value;
    }

    function adminAsNumber() external view returns (uint256) {
        return total; // tras deposit, esto YA NO es el admin
    }
}

/// @title GoodLogic — respeta EIP-1967 (slots dedicados del proxy) y deja gap
contract GoodLogic {
    // Nunca usamos slot 0/1 para estado propio cuando el proxy los usa.
    // En un proxy EIP-1967 real, admin/impl están en slots keccak especiales.
    // Acá simulamos dejando un gap alineado:
    address private _gapAdmin;          // slot 0 (ocupado por proxy)
    address private _gapImpl;           // slot 1
    uint256 public total;               // slot 2 — seguro
    mapping(address => uint256) public bal;

    function deposit() external payable {
        total += msg.value;
        bal[msg.sender] += msg.value;
    }
}

/// @title SimpleProxy — guarda admin/impl en slots 0 y 1 (anti-patrón didáctico)
contract SimpleProxy {
    address public admin;          // slot 0
    address public implementation; // slot 1

    constructor(address impl, address admin_) {
        admin = admin_;
        implementation = impl;
    }

    function upgrade(address n) external {
        require(msg.sender == admin, "admin");
        implementation = n;
    }

    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let r := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch r
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
    receive() external payable {}
}

/// @title UninitializedProxy — riesgo de init front-run
contract InitLogic {
    address public owner;
    bool public initialized;
    function initialize(address o) external {
        require(!initialized, "init");
        initialized = true;
        owner = o;
    }
    function sensitive() external view returns (address) { return owner; }
}
