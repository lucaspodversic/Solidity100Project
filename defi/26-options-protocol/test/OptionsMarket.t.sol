// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionsMarket} from "../src/OptionsMarket.sol";
import {PriceOracle} from "../src/oracle/PriceOracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract OptionsMarketTest is Test {
    MockERC20 weth;
    MockERC20 usdc;
    PriceOracle oracle;
    OptionsMarket opt;

    address writer = makeAddr("writer");
    address writer2 = makeAddr("writer2");
    address bob = makeAddr("bob");

    uint64 expiry;
    uint256 constant K = 2000e18;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new PriceOracle();
        oracle.setMaxAge(3650 days);
        oracle.setPrice(address(weth), 2000e18);
        opt = new OptionsMarket(weth, usdc, oracle);
        expiry = uint64(vm.getBlockTimestamp() + 30 days);

        for (uint256 i; i < 2; i++) {
            address w = i == 0 ? writer : writer2;
            weth.mint(w, 100e18);
            usdc.mint(w, 1_000_000e6);
            vm.startPrank(w);
            weth.approve(address(opt), type(uint256).max);
            usdc.approve(address(opt), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev El writer lanza y "vende" (transfiere) las opciones a bob.
    function _writeAndSell(bool isCall, uint256 amount) internal returns (uint256 id) {
        id = opt.seriesId(isCall, K, expiry);
        if (!_exists(id)) opt.createSeries(isCall, K, expiry);
        vm.startPrank(writer);
        opt.write(id, amount);
        opt.safeTransferFrom(writer, bob, id, amount, "");
        vm.stopPrank();
    }

    function _exists(uint256 id) internal view returns (bool e) {
        (,,, e,,,) = opt.series(id);
    }

    function _expireAt(uint256 price) internal {
        vm.warp(expiry + 10 minutes);
        oracle.setPrice(address(weth), price);
    }

    function test_CallITM() public {
        uint256 id = _writeAndSell(true, 2e18);
        assertEq(weth.balanceOf(address(opt)), 2e18);
        _expireAt(2500e18);
        opt.settle(id);
        vm.prank(bob);
        assertEq(opt.exercise(id, 2e18), 0.4e18); // 2 · 500/2500
        vm.prank(writer);
        assertEq(opt.redeemWriter(id), 1.6e18); // 2 · 2000/2500
        assertEq(weth.balanceOf(address(opt)), 0);
    }

    function test_CallOTM() public {
        uint256 id = _writeAndSell(true, 2e18);
        _expireAt(1800e18);
        opt.settle(id);
        vm.prank(bob);
        assertEq(opt.exercise(id, 2e18), 0);
        vm.prank(writer);
        assertEq(opt.redeemWriter(id), 2e18);
    }

    function test_PutITM() public {
        uint256 id = _writeAndSell(false, 3e18);
        assertEq(usdc.balanceOf(address(opt)), 6_000e6); // strike·cantidad
        _expireAt(1500e18);
        opt.settle(id);
        vm.prank(bob);
        assertEq(opt.exercise(id, 3e18), 1_500e6);
        vm.prank(writer);
        assertEq(opt.redeemWriter(id), 4_500e6);
        assertEq(usdc.balanceOf(address(opt)), 0);
    }

    function test_PutOTM() public {
        uint256 id = _writeAndSell(false, 1e18);
        _expireAt(2600e18);
        opt.settle(id);
        vm.prank(writer);
        assertEq(opt.redeemWriter(id), 2_000e6);
    }

    function test_CloseWriteBeforeExpiry() public {
        uint256 id = opt.createSeries(true, K, expiry);
        vm.startPrank(writer);
        opt.write(id, 5e18);
        opt.closeWrite(id, 5e18);
        vm.stopPrank();
        assertEq(weth.balanceOf(writer), 100e18);
        assertEq(opt.written(id, writer), 0);
    }

    function test_CloseWriteRequiresTokensAndShortPosition() public {
        uint256 id = _writeAndSell(true, 1e18);
        // el writer ya no tiene los tokens
        vm.prank(writer);
        vm.expectRevert();
        opt.closeWrite(id, 1e18);
        // bob tiene tokens pero no lanzó: no puede llevarse colateral ajeno
        vm.prank(bob);
        vm.expectRevert();
        opt.closeWrite(id, 1e18);
    }

    function test_TimeRules() public {
        uint256 id = opt.createSeries(false, K, expiry);
        vm.expectRevert(OptionsMarket.NotExpired.selector);
        opt.settle(id);
        vm.expectRevert(OptionsMarket.NotSettled.selector);
        opt.exercise(id, 1);

        vm.warp(expiry);
        vm.prank(writer);
        vm.expectRevert(OptionsMarket.Expired.selector);
        opt.write(id, 1e18);

        // nadie liquidó en la ventana → solo manual, y recién después de MANUAL_DELAY
        vm.warp(expiry + 2 hours);
        vm.expectRevert(OptionsMarket.WindowClosed.selector);
        opt.settle(id);
        vm.expectRevert(OptionsMarket.TooEarlyForManual.selector);
        opt.settleManual(id, 1900e18);
        vm.warp(expiry + 1 days);
        vm.prank(bob);
        vm.expectRevert(); // onlyOwner
        opt.settleManual(id, 1900e18);
        opt.settleManual(id, 1900e18);
        vm.expectRevert(OptionsMarket.AlreadySettled.selector);
        opt.settleManual(id, 1900e18);
    }

    function test_SeriesValidation() public {
        vm.expectRevert(OptionsMarket.BadParams.selector);
        opt.createSeries(true, 0, expiry);
        vm.expectRevert(OptionsMarket.BadParams.selector);
        opt.createSeries(true, K, uint64(vm.getBlockTimestamp()));
        opt.createSeries(true, K, expiry);
        vm.expectRevert(OptionsMarket.BadParams.selector);
        opt.createSeries(true, K, expiry);
        vm.expectRevert(OptionsMarket.UnknownSeries.selector);
        opt.write(123, 1);
    }

    function test_IntrinsicValueAndPutCallParityAtExpiry() public {
        uint256 c = opt.createSeries(true, K, expiry);
        uint256 p = opt.createSeries(false, K, expiry);
        oracle.setPrice(address(weth), 2300e18);
        assertEq(opt.intrinsicValue(c), 300e18);
        assertEq(opt.intrinsicValue(p), 0);
        // paridad al vencimiento: C − P = S − K
        oracle.setPrice(address(weth), 1700e18);
        assertEq(int256(opt.intrinsicValue(c)) - int256(opt.intrinsicValue(p)), int256(1700e18) - int256(K));
    }

    /// @notice Solvencia: para cualquier precio y cantidades, holders + writers cobran ≤ colateral
    ///         y el polvo que queda es mínimo.
    function testFuzz_Solvency(bool isCall, uint256 a1, uint256 a2, uint256 price) public {
        a1 = bound(a1, 1, 50e18);
        a2 = bound(a2, 1, 50e18);
        price = bound(price, 1e18, 10_000e18);
        uint256 id = opt.createSeries(isCall, K, expiry);
        vm.prank(writer);
        opt.write(id, a1);
        vm.prank(writer2);
        opt.write(id, a2);
        // ambos venden a bob
        vm.prank(writer);
        opt.safeTransferFrom(writer, bob, id, a1, "");
        vm.prank(writer2);
        opt.safeTransferFrom(writer2, bob, id, a2, "");

        _expireAt(price);
        opt.settle(id);
        vm.prank(bob);
        opt.exercise(id, a1 + a2);
        vm.prank(writer);
        opt.redeemWriter(id);
        vm.prank(writer2);
        opt.redeemWriter(id);

        uint256 dust = (isCall ? weth : usdc).balanceOf(address(opt));
        assertLe(dust, 4); // solo redondeos, nunca faltante (si faltara, un transfer revertiría)
    }
}
