// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VulnerableToken — ERC20 con vulnerabilidades intencionadas
/// @author Proyecto 54
contract VulnerableToken {
    string public name = "VulnToken";
    string public symbol = "VULN";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    address public owner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // H-01: transfer no retorna bool (rompe interoperabilidad) — acá sí retornamos pero...
    // H-02: approve race (classic) — sin decrease/increase
    // H-03: burnFrom sin allowance
    // H-04: mint abierto
    // M-01: fee on transfer oculto que rompe AMMs
    uint256 public feeBps = 100; // 1%

    constructor() {
        owner = msg.sender;
        _mint(msg.sender, 1_000_000e18);
    }

    function _mint(address to, uint256 a) internal {
        balanceOf[to] += a;
        totalSupply += a;
    }

    /// @notice H-04: cualquiera puede mintear
    function mint(address to, uint256 a) external { _mint(to, a); }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        // H-02: permite race front-run del spender
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        allowance[from][msg.sender] = allowed - amount;
        return _transfer(from, to, amount);
    }

    /// @notice H-03: burnFrom ignora allowance
    function burnFrom(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 send = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += send;
        balanceOf[owner] += fee; // fee silencioso
        return true;
    }
}

/// @title SafeToken — parches
contract SafeToken {
    string public name = "SafeToken";
    string public symbol = "SAFE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    address public owner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }

    constructor() { owner = msg.sender; _mint(msg.sender, 1_000_000e18); }

    function _mint(address to, uint256 a) internal { balanceOf[to]+=a; totalSupply+=a; }

    function mint(address to, uint256 a) external onlyOwner { _mint(to, a); }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Mitiga race: solo permite setear 0 o desde 0
    function safeApprove(address spender, uint256 amount) external returns (bool) {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "race");
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burnFrom(address from, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}
