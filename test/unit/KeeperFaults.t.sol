// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {KeeperScenario} from "../utils/KeeperScenario.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {TradeGuard} from "../../src/TradeGuard.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";

contract KeeperFaultsTest is KeeperScenario {
    function _smallLine() private returns (CreditLine line) {
        line = _openLine(alice, 1_000e6, 2_000e6);
        _long(line, 6_000, 300);
    }

    function _atEighty(uint256 spread) private returns (Settlement memory s) {
        CreditLine line = _smallLine();
        _spread(spread);
        vm.warp(block.timestamp + 60);
        ex.setMark(BTC, BTC_PRICE * 80 / 100);
        vm.prank(keeper);
        line.freeze();
        _exitPosition(line);
        return _settleChecked(line);
    }

    function test_baselineFillMatchesHandCalculation() public {
        Settlement memory s = _atEighty(5);
        assertEq(s.lost, 219_720_622);
    }

    function test_adverseFillMatchesHandCalculation() public {
        Settlement memory s = _atEighty(50);
        assertEq(s.lost, 241_311_982);
    }

    function test_unfillableGuardEdgePreservesPositionUntilValidFill() public {
        CreditLine line = _smallLine();
        ex.setMark(BTC, BTC_PRICE * 80 / 100);
        vm.prank(keeper);
        line.freeze();
        _spread(51);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.ExchangeCallFailed.selector, abi.encodeWithSignature("NotFilled()")));
        line.unwind(BTC, type(uint256).max);
        (IExchange.PositionInfoV2 memory p,,) = ex.getPositionV2(BTC, line.account().accountId());
        assertEq(p.lotLNS, 6_000);
        assertEq(line.principal(), 2_000e6);
        _spread(50);
        _exitPosition(line);
        _settleChecked(line);
    }

    function test_fastKeeperAvoidsTheLaterCrashLoss() public {
        CreditLine line = _smallLine();
        uint256 start = block.timestamp;
        vm.warp(start + 60);
        ex.setMark(BTC, BTC_PRICE * 85 / 100);
        assertLt(line.healthBps(), manager.riskParams().freezeHealthBps);
        vm.prank(keeper);
        line.freeze();
        _exitPosition(line);
        Settlement memory s = _settleChecked(line);
        assertEq(s.lost, 0);
        vm.warp(start + 180);
        ex.setMark(BTC, BTC_PRICE * 60 / 100);
        assertEq(uint256(line.state()), uint256(CreditLine.State.Closed));
        assertEq(pool.totalLosses(), 0);
    }

    function test_lateKeeperRealizesLossAfterTwoMinuteDelay() public {
        CreditLine line = _smallLine();
        uint256 start = block.timestamp;
        vm.warp(start + 60);
        ex.setMark(BTC, BTC_PRICE * 85 / 100);
        assertLt(line.healthBps(), manager.riskParams().freezeHealthBps);
        vm.warp(start + 180);
        ex.setMark(BTC, BTC_PRICE * 60 / 100);
        vm.prank(keeper);
        line.freeze();
        _exitPosition(line);
        Settlement memory s = _settleChecked(line);
        assertEq(s.lost, 1_013_402_347);
    }

    function test_staleMarkRejectsNewRiskThenAcceptsFreshControl() public {
        CreditLine line = _smallLine();
        uint256 timestamp = block.timestamp;
        vm.warp(timestamp + 121);
        IExchange.OrderDesc[] memory orders = _order(0, BTC_PRICE * 10_040 / 10_000, 100, 200);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.StaleMark.selector, timestamp));
        line.trade(orders);
        ex.setMark(BTC, BTC_PRICE);
        _long(line, 100, 200);
    }

    function test_staleMarkBlocksFrozenUnwindUntilAdverseRefresh() public {
        CreditLine line = _smallLine();
        ex.setMark(BTC, BTC_PRICE * 85 / 100);
        vm.prank(keeper);
        line.freeze();
        uint256 timestamp = block.timestamp;
        vm.warp(timestamp + 121);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.StaleMark.selector, timestamp));
        line.unwind(BTC, type(uint256).max);
        assertEq(uint256(line.state()), uint256(CreditLine.State.Frozen));
        ex.setMark(BTC, BTC_PRICE * 60 / 100);
        _exitPosition(line);
        Settlement memory s = _settleChecked(line);
        assertGt(s.lost, 1_000e6);
    }

    function test_correlatedLossExhaustsReserveAndJuniorBeforeSenior() public {
        CreditLine[4] memory lines = _fundedPortfolio(true);
        ex.setMark(BTC, BTC_PRICE * 60 / 100);
        uint256 seniorLoss;
        for (uint256 i; i < 4; ++i) {
            vm.prank(keeper);
            lines[i].freeze();
            _exitPosition(lines[i]);
            Settlement memory s = _settleChecked(lines[i]);
            seniorLoss += s.seniorLoss;
        }
        assertEq(pool.reserve(), 0);
        assertEq(pool.juniorAssets(), 0);
        assertGt(seniorLoss, 0);
        assertEq(pool.principalOutstanding(), 0);
        _identity();
    }

    function test_fifoHeadBlocksPayableTailThenRecoveryReleasesInOrder() public {
        CreditLine[4] memory lines = _fundedPortfolio(false);
        _enqueue();
        assertGt(senior.previewRedeem(senior.queuedShares()), pool.withdrawable(senior.tranche()));
        assertEq(senior.processQueue(2), 0);
        assertEq(senior.head(), 0);
        (address tailOwner, uint256 tailShares) = senior.queue(1);
        assertGt(tailShares, 0);
        assertLt(senior.previewRedeem(tailShares), pool.withdrawable(senior.tranche()));
        uint256 tailCash = ausd.balanceOf(tailOwner);
        _exitPosition(lines[0]);
        _settleChecked(lines[0]);
        assertEq(senior.processQueue(2), 1);
        assertEq(senior.head(), 1);
        assertEq(ausd.balanceOf(tailOwner), tailCash);
        _exitPosition(lines[1]);
        _settleChecked(lines[1]);
        assertEq(senior.processQueue(2), 1);
        assertEq(senior.head(), 2);
        assertGt(ausd.balanceOf(tailOwner), tailCash);
        _identity();
    }

    function test_configuredMarketPath() public {
        string memory raw = vm.envOr("H3_STRESS_PROTOCOL_JSON", string(""));
        uint256[] memory marks;
        uint256 every = 1;
        uint256 spread = 5;
        string memory label = "synthetic_control";
        if (bytes(raw).length == 0) {
            marks = new uint256[](4);
            marks[0] = BTC_PRICE; marks[1] = BTC_PRICE * 85 / 100;
            marks[2] = BTC_PRICE * 60 / 100; marks[3] = marks[2];
        } else {
            marks = vm.parseJsonUintArray(raw, ".prices_pns");
            every = vm.parseJsonUint(raw, ".keeper_every_minutes");
            spread = vm.parseJsonUint(raw, ".exit_spread_bps");
            label = vm.parseJsonString(raw, ".label");
        }
        _run(marks, every, spread, label);
    }
}
