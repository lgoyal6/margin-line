// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../utils/Fixture.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {TradeGuard} from "../../src/TradeGuard.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";

/// @notice Concentration and exposure limits: no single line can take too much of the pool, and no
///         line can build too large a position in one market.
contract CapsTest is Fixture {
    function test_lineCannotExceedConcentrationLimit() public {
        // Pool is 1,000,000 of lender capital at the default 25% limit: 250,000 is the most one line gets.
        _registerPasskey(alice);
        _approve(alice, 250_001e6);
        ausd.mint(alice, 100_000e6);
        vm.startPrank(alice);
        ausd.approve(address(manager), 100_000e6);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.LineTooLarge.selector, 250_001e6, 250_000e6));
        manager.openLine(100_000e6, 250_001e6);
        vm.stopPrank();

        CreditLine line = _openLine(alice, 100_000e6, 250_000e6);
        assertEq(pool.principalOf(address(line)), 250_000e6);
    }

    function test_concentrationLimitScalesWithThePool() public {
        _lend(makeAddr("lender2"), 1_000_000e6); // pool now 2,000,000
        CreditLine line = _openLine(alice, 200_000e6, 500_000e6);
        assertEq(pool.principalOf(address(line)), 500_000e6);
    }

    function test_onlyOwnerSetsConcentrationLimit() public {
        vm.prank(alice);
        vm.expectRevert();
        manager.setMaxLineBps(10_000);
        vm.startPrank(admin);
        vm.expectRevert(CreditManager.InvalidParams.selector);
        manager.setMaxLineBps(0);
        vm.expectRevert(CreditManager.InvalidParams.selector);
        manager.setMaxLineBps(10_001);
        vm.stopPrank();
    }

    function test_exposureCapBlocksOversizedPosition() public {
        vm.prank(admin);
        guard.setExposureCap(BTC, 2_000e6);
        CreditLine line = _openLine(alice, 1_000e6, 2_000e6);

        _long(line, 1_500, 200); // $1,500: under the cap
        IExchange.OrderDesc[] memory o = _order(0, (ex.mark(BTC) * 10_040) / 10_000, 600, 200);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.ExposureTooLarge.selector, BTC, 2_100e6, 2_000e6));
        line.trade(o); // would make the position $2,100
    }

    function test_closingIsAllowedAboveTheCap() public {
        CreditLine line = _openLine(alice, 1_000e6, 2_000e6);
        _long(line, 2_000, 200);
        vm.prank(admin);
        guard.setExposureCap(BTC, 1_000e6); // cap lowered below the existing position
        _closeLong(line, 500); // reducing risk is never blocked
        // But adding to it is.
        IExchange.OrderDesc[] memory o = _order(0, (ex.mark(BTC) * 10_040) / 10_000, 1, 200);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.ExposureTooLarge.selector, BTC, 1_501e6, 1_000e6));
        line.trade(o);
    }

    function test_exposureMeasuredAtMark() public {
        vm.prank(admin);
        guard.setExposureCap(BTC, 2_000e6);
        CreditLine line = _openLine(alice, 1_000e6, 2_000e6);
        _long(line, 1_900, 200);
        ex.setMark(BTC, (BTC_PRICE * 110) / 100); // +10%: 1,900 lots are now $2,090; one more makes $2,091.10
        IExchange.OrderDesc[] memory o = _order(0, (ex.mark(BTC) * 10_040) / 10_000, 1, 200);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.ExposureTooLarge.selector, BTC, 2_091.1e6, 2_000e6));
        line.trade(o);
    }
}
