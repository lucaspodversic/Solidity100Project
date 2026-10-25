// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IPriceOracle} from "../src/IPriceOracle.sol";
import {ManualOracle, FixedOracle} from "../src/Oracles.sol";
import {PriceConsumer} from "../src/PriceConsumer.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") { _mint(msg.sender, 5 ether); }
}

contract InterfacesTest is Test {
    bytes32 constant ETH = "ETH";
    ManualOracle manual;
    FixedOracle fixedO;
    PriceConsumer consumer;

    function setUp() public {
        manual = new ManualOracle();
        manual.setPrice(ETH, 3000e8);
        fixedO = new FixedOracle(1e8);
        consumer = new PriceConsumer(manual);
    }

    function test_ValorConOracleManual() public view {
        assertEq(consumer.valueOf(ETH, 2 ether), 6000e8);
    }

    function test_CambioDeImplementacion() public {
        consumer.setOracle(fixedO);
        assertEq(consumer.valueOf(ETH, 2 ether), 2e8);
    }

    function test_PortfolioConIERC20() public {
        MockToken t = new MockToken();
        assertEq(consumer.portfolioValue(t, ETH, address(this)), 15000e8);
    }

    function test_InterfaceId() public pure {
        // El ID de interfaz (ERC-165) es el XOR de los selectores.
        bytes4 id = IPriceOracle.getPrice.selector ^ IPriceOracle.decimals.selector;
        assertEq(id, type(IPriceOracle).interfaceId);
    }

    function test_RevertActivoDesconocido() public {
        vm.expectRevert(abi.encodeWithSelector(ManualOracle.UnknownAsset.selector, bytes32("BTC")));
        consumer.valueOf("BTC", 1);
    }

    function test_SoloOwnerCambia() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(PriceConsumer.NotOwner.selector);
        consumer.setOracle(fixedO);
    }
}
