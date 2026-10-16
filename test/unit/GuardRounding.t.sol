// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../utils/Fixture.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {TradeGuard} from "../../src/TradeGuard.sol";

contract GuardRoundingTest is Fixture {
    function _checkEdges(uint256 mark, uint16 band) private {
        vm.prank(admin);
        guard.setMarket(BTC, true, 300, band);
        ex.setMark(BTC, mark);
        uint256 sell = guard.closePrice(IExchange(address(ex)), BTC, true);
        uint256 buy = guard.closePrice(IExchange(address(ex)), BTC, false);
        assertGe(sell * 10_000, mark * (10_000 - band));
        assertLe(buy * 10_000, mark * (10_000 + band));
        assertFalse(guard.checkOrders(IExchange(address(ex)), _order(2, sell, 1, 100)));
        assertFalse(guard.checkOrders(IExchange(address(ex)), _order(3, buy, 1, 100)));

        IExchange.OrderDesc[] memory low = _order(2, sell - 1, 1, 100);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.PriceOutsideBand.selector, sell - 1, mark, band));
        guard.checkOrders(IExchange(address(ex)), low);
        IExchange.OrderDesc[] memory high = _order(3, buy + 1, 1, 100);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.PriceOutsideBand.selector, buy + 1, mark, band));
        guard.checkOrders(IExchange(address(ex)), high);
    }

    function test_fractionalSellAndBuyEdges() public {
        _checkEdges(979_980, 50);
    }

    function test_integralSellAndBuyEdges() public {
        _checkEdges(1_000_000, 50);
    }

    function testFuzz_quotesAndAdjacentTicksRespectExactBand(uint64 rawMark, uint16 rawBand) public {
        _checkEdges(bound(rawMark, 1, type(uint64).max), uint16(bound(rawBand, 1, 500)));
    }
}
