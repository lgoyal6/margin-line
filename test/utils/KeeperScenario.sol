// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "./Fixture.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/// @dev Schedules the existing contracts and mock venue; no RPC or fork is used.
abstract contract KeeperScenario is Fixture {
    using stdStorage for StdStorage;
    uint256 internal constant NEVER = type(uint256).max;

    struct Book {
        uint256 senior;
        uint256 junior;
        uint256 reserve;
        uint256 cash;
        uint256 outstanding;
        uint256 shortfall;
        uint256 lastAccrual;
    }

    struct Settlement {
        uint256 principal;
        uint256 recovered;
        uint256 bounty;
        uint256 interest;
        uint256 repaid;
        uint256 lost;
        uint256 borrower;
        uint256 reserveLoss;
        uint256 juniorLoss;
        uint256 seniorLoss;
    }

    struct Campaign {
        uint256 loss;
        uint256 reserveLoss;
        uint256 juniorLoss;
        uint256 seniorLoss;
        uint256 interest;
        uint256 bounty;
        uint256 paidRequests;
        uint256 maxBacklog;
        uint256[4] firstBreach;
        uint256[4] frozenAt;
    }

    function _book() internal view returns (Book memory b) {
        b = Book(pool.seniorAssets(), pool.juniorAssets(), pool.reserve(), ausd.balanceOf(address(pool)),
            pool.principalOutstanding(), pool.seniorShortfall(), pool.lastSeniorAccrual());
    }

    function _identity() internal view {
        Book memory b = _book();
        assertEq(b.senior + b.junior + b.reserve, b.cash + b.outstanding, "pool cash/principal identity");
    }

    function _spread(uint256 bps) internal {
        require(bps <= 10_000, "invalid mock spread");
        stdstore.target(address(ex)).sig("spreadBps()").checked_write(bps);
        assertEq(ex.spreadBps(), bps);
    }

    function _exitPosition(CreditLine line) internal {
        (IExchange.PositionInfoV2 memory p,,) = ex.getPositionV2(BTC, line.account().accountId());
        if (p.lotLNS == 0) return;
        if (line.state() == CreditLine.State.Frozen) {
            vm.prank(keeper);
            line.unwind(BTC, type(uint256).max);
        } else {
            bool isLong = IExchange.PositionEnum.unwrap(p.positionType) == 0;
            IExchange.OrderDesc[] memory orders = _order(
                isLong ? 2 : 3, guard.closePrice(IExchange(address(ex)), BTC, isLong), p.lotLNS, 100
            );
            address borrower = line.borrower();
            vm.prank(borrower);
            line.trade(orders);
        }
    }

    function _settleChecked(CreditLine line) internal returns (Settlement memory s) {
        Book memory before_ = _book();
        s.principal = line.principal();
        s.recovered = line.equity(); // Position was fully unwound; this is recoverable cash.
        uint256 numerator = s.principal * line.aprBps() * (block.timestamp - line.lastAccrual());
        uint256 owed = line.interestOwed() + (numerator + 10_000 * 365 days - 1) / (10_000 * 365 days);
        assertEq(line.debt(), s.principal + owed, "simple interest oracle");
        uint256 promisedBounty;
        if (line.state() == CreditLine.State.Frozen) {
            // Freeze already accrued interest and fixed the bounty at lastAccrual.
            promisedBounty = (s.principal + line.interestOwed()) * manager.freezeBountyBps() / 10_000;
            if (promisedBounty > manager.maxFreezeBounty()) promisedBounty = manager.maxFreezeBounty();
        }
        assertEq(line.bountyOwed(), promisedBounty, "freeze bounty oracle");
        s.bounty = _min(s.recovered, promisedBounty);
        s.interest = _min(s.recovered - s.bounty, owed);
        s.repaid = _min(s.recovered - s.bounty - s.interest, s.principal);
        s.lost = s.principal - s.repaid;
        s.borrower = s.recovered - s.bounty - s.interest - s.repaid;

        uint256 keeperBefore = ausd.balanceOf(keeper);
        uint256 borrowerBefore = ausd.balanceOf(line.borrower());
        uint256 lossBefore = pool.totalLosses();
        if (line.state() == CreditLine.State.Frozen) {
            vm.prank(keeper);
            line.settleFrozen();
        } else {
            _close(line);
        }
        assertEq(uint256(line.state()), uint256(CreditLine.State.Closed));
        assertEq(ausd.balanceOf(keeper) - keeperBefore, s.bounty);
        assertEq(ausd.balanceOf(line.borrower()) - borrowerBefore, s.borrower);
        assertEq(pool.totalLosses() - lossBefore, s.lost);
        assertEq(before_.outstanding - pool.principalOutstanding(), s.principal);
        assertEq(ausd.balanceOf(address(pool)) - before_.cash, s.repaid + s.interest);
        assertEq(s.repaid + s.lost, s.principal);
        assertEq(s.bounty + s.interest + s.repaid + s.borrower, s.recovered);
        _allocationOracle(before_, s);
        _identity();
        _settlementTrace(line, before_, s, owed, promisedBounty);
    }

    function _settlementTrace(CreditLine line, Book memory b, Settlement memory s, uint256 owed, uint256 promised)
        private
    {
        vm.serializeAddress("settlement", "line", address(line));
        vm.serializeUint("settlement", "timestamp", block.timestamp);
        vm.serializeUint("settlement", "before_senior", b.senior);
        vm.serializeUint("settlement", "before_junior", b.junior);
        vm.serializeUint("settlement", "before_reserve", b.reserve);
        vm.serializeUint("settlement", "before_cash", b.cash);
        vm.serializeUint("settlement", "before_outstanding", b.outstanding);
        vm.serializeUint("settlement", "before_shortfall", b.shortfall);
        vm.serializeUint("settlement", "before_last_accrual", b.lastAccrual);
        vm.serializeUint("settlement", "principal", s.principal);
        vm.serializeUint("settlement", "recovered", s.recovered);
        vm.serializeUint("settlement", "interest_owed", owed);
        vm.serializeUint("settlement", "bounty_promised", promised);
        vm.serializeUint("settlement", "bounty", s.bounty);
        vm.serializeUint("settlement", "interest", s.interest);
        vm.serializeUint("settlement", "repaid", s.repaid);
        vm.serializeUint("settlement", "lost", s.lost);
        vm.serializeUint("settlement", "borrower", s.borrower);
        vm.serializeUint("settlement", "reserve_loss", s.reserveLoss);
        vm.serializeUint("settlement", "junior_loss", s.juniorLoss);
        vm.serializeUint("settlement", "senior_loss", s.seniorLoss);
        vm.serializeUint("settlement", "after_senior", pool.seniorAssets());
        vm.serializeUint("settlement", "after_junior", pool.juniorAssets());
        vm.serializeUint("settlement", "after_reserve", pool.reserve());
        vm.serializeUint("settlement", "after_cash", ausd.balanceOf(address(pool)));
        emit log(string.concat("H3_SETTLEMENT ", vm.serializeUint("settlement", "after_outstanding", pool.principalOutstanding())));
    }

    function _allocationOracle(Book memory b, Settlement memory s) private view {
        uint256 due = b.shortfall;
        uint256 dt = block.timestamp - b.lastAccrual;
        if (b.senior + b.junior != 0) {
            uint256 deployed = b.outstanding * b.senior / (b.senior + b.junior);
            due += deployed * pool.seniorAprBps() * dt / (10_000 * 365 days);
        }
        uint256 reserveInterest = s.interest * pool.reserveBps() / 10_000;
        uint256 seniorInterest = _min(s.interest - reserveInterest, due);
        uint256 juniorInterest = s.interest - reserveInterest - seniorInterest;
        s.reserveLoss = _min(s.lost, b.reserve + reserveInterest);
        s.juniorLoss = _min(s.lost - s.reserveLoss, b.junior + juniorInterest);
        s.seniorLoss = s.lost - s.reserveLoss - s.juniorLoss;
        assertEq(pool.reserve(), b.reserve + reserveInterest - s.reserveLoss);
        assertEq(pool.juniorAssets(), b.junior + juniorInterest - s.juniorLoss);
        assertEq(pool.seniorAssets(), b.senior + seniorInterest - s.seniorLoss);
        assertEq(pool.seniorShortfall(), due - seniorInterest);
    }

    function _fundedPortfolio(bool allLong) internal returns (CreditLine[4] memory lines) {
        vm.prank(lender);
        junior.withdraw(980_000e6, lender, lender);
        CreditLine seed = _openLine(makeAddr("reserve-seed"), 2_000e6, 4_000e6);
        vm.warp(block.timestamp + 365 days);
        _settleChecked(seed);
        assertEq(pool.reserve(), 40e6);
        assertEq(pool.juniorAssets(), 20_360e6);
        _lendTo(senior, makeAddr("senior-a"), 40_000e6);
        _lendTo(senior, makeAddr("senior-b"), 40_000e6);
        ex.setMark(BTC, BTC_PRICE);
        for (uint256 i; i < 4; ++i) {
            address borrower = makeAddr(string.concat("keeper-borrower-", vm.toString(i)));
            lines[i] = _openLine(borrower, 10_000e6, 20_000e6);
            if (allLong || i % 2 == 0) _long(lines[i], 70_000, 300);
            else {
                IExchange.OrderDesc[] memory orders = _order(1, BTC_PRICE * 9_960 / 10_000, 70_000, 300);
                vm.prank(borrower);
                lines[i].trade(orders);
            }
        }
        assertEq(pool.principalOutstanding(), 80_000e6);
        _identity();
    }

    function _enqueue() internal {
        address a = makeAddr("senior-a");
        address b = makeAddr("senior-b");
        uint256 first = senior.balanceOf(a);
        uint256 second = senior.balanceOf(b) / 40;
        vm.prank(a);
        assertEq(senior.requestRedeem(first), 0);
        vm.prank(b);
        assertEq(senior.requestRedeem(second), 1);
    }

    function _account(Campaign memory r, Settlement memory s) private pure {
        r.loss += s.lost;
        r.reserveLoss += s.reserveLoss;
        r.juniorLoss += s.juniorLoss;
        r.seniorLoss += s.seniorLoss;
        r.interest += s.interest;
        r.bounty += s.bounty;
    }

    function _run(uint256[] memory marks, uint256 every, uint256 spread, string memory label)
        internal returns (Campaign memory r)
    {
        require(marks.length >= 2 && marks.length <= 1_441 && marks[0] == BTC_PRICE, "invalid path");
        require(every > 0 && spread <= 50, "invalid schedule/fill");
        CreditLine[4] memory lines = _fundedPortfolio(false);
        _enqueue();
        _spread(spread); // Entries remain at 5bp; only unwind/terminal fills vary.
        uint256 start = block.timestamp;
        for (uint256 i; i < 4; ++i) r.firstBreach[i] = r.frozenAt[i] = NEVER;
        for (uint256 minute; minute < marks.length; ++minute) {
            require(marks[minute] > 0, "zero mark");
            vm.warp(start + minute * 60);
            ex.setMark(BTC, marks[minute]);
            uint256[] memory health = new uint256[](4);
            for (uint256 i; i < 4; ++i) {
                if (lines[i].state() == CreditLine.State.Closed) continue;
                health[i] = lines[i].healthBps();
                if (health[i] < manager.riskParams().freezeHealthBps && r.firstBreach[i] == NEVER) {
                    r.firstBreach[i] = minute * 60;
                }
            }
            if (minute % every == 0 || minute == marks.length - 1) {
                for (uint256 i; i < 4; ++i) {
                    if (lines[i].state() != CreditLine.State.Active
                        || lines[i].healthBps() >= manager.riskParams().freezeHealthBps) continue;
                    vm.prank(keeper);
                    lines[i].freeze();
                    r.frozenAt[i] = minute * 60;
                    _exitPosition(lines[i]);
                    _account(r, _settleChecked(lines[i]));
                }
                r.paidRequests += senior.processQueue(2);
            }
            uint256 backlog = senior.previewRedeem(senior.queuedShares());
            if (backlog > r.maxBacklog) r.maxBacklog = backlog;
            _identity();
            _trace(minute, marks[minute], health, false);
        }
        // Explicit model boundary: surviving borrowers cooperate with terminal close.
        for (uint256 i; i < 4; ++i) {
            if (lines[i].state() == CreditLine.State.Closed) continue;
            _exitPosition(lines[i]);
            _account(r, _settleChecked(lines[i]));
        }
        r.paidRequests += senior.processQueue(2);
        assertEq(senior.head(), senior.queueLength());
        assertEq(pool.principalOutstanding(), 0);
        assertEq(r.loss, r.reserveLoss + r.juniorLoss + r.seniorLoss);
        _identity();
        _trace(marks.length - 1, marks[marks.length - 1], new uint256[](4), true);
        _summary(r, label);
    }

    function _trace(uint256 minute, uint256 price, uint256[] memory health, bool terminal) private {
        vm.serializeUint("step", "minute", minute);
        vm.serializeUint("step", "price_pns", price);
        vm.serializeUint("step", "health_before_keeper_bps", health);
        vm.serializeUint("step", "senior_micro", pool.seniorAssets());
        vm.serializeUint("step", "junior_micro", pool.juniorAssets());
        vm.serializeUint("step", "reserve_micro", pool.reserve());
        vm.serializeUint("step", "cash_micro", ausd.balanceOf(address(pool)));
        vm.serializeUint("step", "principal_micro", pool.principalOutstanding());
        vm.serializeUint("step", "queue_head", senior.head());
        vm.serializeUint("step", "queued_assets_micro", senior.previewRedeem(senior.queuedShares()));
        emit log(string.concat("H3_STEP ", vm.serializeBool("step", "terminal", terminal)));
    }

    function _summary(Campaign memory r, string memory label) private {
        vm.serializeString("result", "label", label);
        vm.serializeUint("result", "loss_micro", r.loss);
        vm.serializeUint("result", "reserve_loss_micro", r.reserveLoss);
        vm.serializeUint("result", "junior_loss_micro", r.juniorLoss);
        vm.serializeUint("result", "senior_loss_micro", r.seniorLoss);
        vm.serializeUint("result", "interest_micro", r.interest);
        vm.serializeUint("result", "bounty_micro", r.bounty);
        vm.serializeUint("result", "paid_requests", r.paidRequests);
        vm.serializeUint("result", "max_backlog_micro", r.maxBacklog);
        uint256[] memory breaches = new uint256[](4);
        uint256[] memory freezes = new uint256[](4);
        for (uint256 i; i < 4; ++i) { breaches[i] = r.firstBreach[i]; freezes[i] = r.frozenAt[i]; }
        vm.serializeUint("result", "first_breach_seconds", breaches);
        emit log(string.concat("H3_RESULT ", vm.serializeUint("result", "frozen_seconds", freezes)));
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) { return a < b ? a : b; }
}
