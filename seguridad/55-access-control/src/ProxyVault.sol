// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VaultLogic — implementación detrás de un proxy transparente simplificado
contract VaultLogic {
    // Storage layout debe coincidir con el proxy
    address public admin;
    address public implementation;
    mapping(address => uint256) public balances;
    bool public initialized;

    event Initialized(address admin);

    function initialize(address admin_) external {
        // VULNERABLE si no se protege: cualquiera puede reinicializar
        require(!initialized, "init");
        initialized = true;
        admin = admin_;
        emit Initialized(admin_);
    }

    function deposit() external payable { balances[msg.sender] += msg.value; }

    function withdraw(uint256 a) external {
        require(balances[msg.sender] >= a, "bal");
        balances[msg.sender] -= a;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "pay");
    }

    function sweep(address to) external {
        require(msg.sender == admin, "admin");
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "pay");
    }
}

/// @title TransparentProxy — delegatecall al implementation
contract TransparentProxy {
    address public admin;
    address public implementation;

    constructor(address impl, address admin_) {
        admin = admin_;
        implementation = impl;
        // Inicializa vía delegatecall
        (bool ok,) = impl.delegatecall(abi.encodeWithSignature("initialize(address)", admin_));
        require(ok, "init");
    }

    function upgrade(address newImpl) external {
        require(msg.sender == admin, "admin");
        implementation = newImpl;
    }

    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
    receive() external payable {}
}

/// @title VaultLogicSafe — initialize protegido con constructor flag + reinitializer
contract VaultLogicSafe {
    address public admin;
    address public implementation; // padding para misma layout
    mapping(address => uint256) public balances;
    bool public initialized;

    function initialize(address admin_) external {
        require(!initialized, "init");
        initialized = true;
        admin = admin_;
    }

    /// @notice En la lógica "naked" (sin proxy) bloqueamos initialize si ya hay código usándose
    ///         como implementación directa: el deployer llama `disableInitializers`.
    function disableInitializers() external {
        initialized = true;
    }

    function deposit() external payable { balances[msg.sender] += msg.value; }
}
