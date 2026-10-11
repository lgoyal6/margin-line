// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Passkeys} from "../utils/Passkeys.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {TrancheVault} from "../../src/TrancheVault.sol";
import {ScoreRules} from "../../src/ScoreRules.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {MockPerplExchange} from "../mocks/MockPerplExchange.sol";
import {MockAUSD} from "../utils/Fixture.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";
import {CircuitBreaker} from "../../src/CircuitBreaker.sol";

/// @notice Drives random sequences of lender, borrower, keeper, market and venue actions.
///         Every action is wrapped so a revert is an allowed outcome; the invariants decide what
///         must always hold no matter which actions succeeded.
contract Handler is Passkeys {
    uint256 internal constant BTC = 1;

    MockAUSD public ausd;
    MockPerplExchange public ex;
    CreditPool public pool;
    TrancheVault public senior;
    TrancheVault public junior;
    CreditManager public manager;
    address public underwriter;
    IdentityRegistry public identity;

    address[] public lenders;
    address[] public borrowers;
    address public keeper = makeAddr("inv-keeper");

    CreditLine[] public lines;
    mapping(address line => uint256) public fundedPrincipal;
    mapping(address line => uint256) public lossOf;
    uint256 public calls;
    // Coverage ghosts: prove the dangerous paths were actually exercised.
    uint256 public opened;
    uint256 public trades;
    uint256 public frozen;
    uint256 public unwinds;
    uint256 public closed;
    uint256 public closesWithLoss;
    uint256 public sweeps;
    uint256 public sessionsGranted;
    uint256 public sessionTrades;
    uint256 public sessionExtractions; // must stay zero
    address public sessionKey = makeAddr("inv-session");
    CircuitBreaker public breaker;
    address public breakerOwner;
    uint256 public bountiesPaid;
    uint256 public maxBountyObserved;
    uint256 public queuedRequests;
    uint256 public queuePaid;
    uint256 public instantWithdrawals;
    uint256 public seniorDeposits;
    // Scored lines: each borrower has a linked Perpl account with a leaf in its own finalized epoch.
    uint256[] public scoreAccount;
    uint256[] public scoreEpoch;
    ScoreRules.Features internal _scoreFeatures;
    uint256 public scoredOpened;
    uint256 public seniorLossesWithCushion; // must stay zero
    uint256 public seniorHits; // senior absorbed a loss after junior and the reserve were gone
    bool internal seniorPaidOut;

    /// @dev Senior may only lose value when the reserve and junior are both exhausted. Actions that
    ///      pay a senior lender out are excluded, since the drop there is a withdrawal, not a loss.
    modifier watchSenior() {
        uint256 before = pool.seniorAssets();
        seniorPaidOut = false;
        _;
        if (!seniorPaidOut && pool.seniorAssets() < before) {
            if (pool.juniorAssets() != 0 || pool.reserve() != 0) seniorLossesWithCushion++;
            else seniorHits++;
        }
    }

    constructor(
        MockAUSD ausd_,
        MockPerplExchange ex_,
        CreditPool pool_,
        TrancheVault senior_,
        TrancheVault junior_,
        CreditManager manager_,
        address underwriter_,
        IdentityRegistry identity_,
        CircuitBreaker breaker_,
        address breakerOwner_
    ) {
        identity = identity_;
        breaker = breaker_;
        breakerOwner = breakerOwner_;
        ausd = ausd_;
        ex = ex_;
        pool = pool_;
        senior = senior_;
        junior = junior_;
        manager = manager_;
        underwriter = underwriter_;
        for (uint256 i; i < 5; ++i) {
            lenders.push(makeAddr(string.concat("inv-lender-", vm.toString(i))));
            address b = makeAddr(string.concat("inv-borrower-", vm.toString(i)));
            borrowers.push(b);
            (bytes32 qx, bytes32 qy) = _pubkey(_pk(b));
            vm.prank(b);
            identity.registerFirstPasskey(qx, qy);
        }
    }

    function linesLength() external view returns (uint256) {
        return lines.length;
    }

    function borrowersLength() external view returns (uint256) {
        return borrowers.length;
    }

    // ------------------------------------------------------------ lenders

    function _vault(bool isSenior) internal view returns (TrancheVault) {
        return isSenior ? senior : junior;
    }

    function lend(uint256 who, uint256 amount, bool isSenior) external watchSenior {
        calls++;
        address l = lenders[who % lenders.length];
        TrancheVault v = _vault(isSenior);
        amount = bound(amount, 1e6, 500_000e6);
        uint256 cap = v.maxDeposit(l);
        if (cap < 1e6) return;
        if (amount > cap) amount = cap;
        ausd.mint(l, amount);
        vm.startPrank(l);
        ausd.approve(address(v), amount);
        v.deposit(amount, l);
        vm.stopPrank();
        if (isSenior) seniorDeposits++;
    }

    function withdraw(uint256 who, uint256 amount, bool isSenior) external watchSenior {
        calls++;
        address l = lenders[who % lenders.length];
        TrancheVault v = _vault(isSenior);
        uint256 max = v.maxWithdraw(l);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(l);
        v.withdraw(amount, l, l);
        instantWithdrawals++;
        if (isSenior) seniorPaidOut = true;
    }

    function requestRedeem(uint256 who, uint256 frac, bool isSenior) external watchSenior {
        calls++;
        address l = lenders[who % lenders.length];
        TrancheVault v = _vault(isSenior);
        uint256 bal = v.balanceOf(l);
        if (bal == 0) return;
        uint256 shares = (bal * bound(frac, 1, 100)) / 100;
        if (shares == 0) return;
        vm.prank(l);
        v.requestRedeem(shares);
        queuedRequests++;
    }

    function cancelRequest(uint256 seed, bool isSenior) external watchSenior {
        calls++;
        TrancheVault v = _vault(isSenior);
        uint256 n = v.queueLength();
        if (n == 0) return;
        uint256 id = seed % n;
        (address owner_, uint256 shares) = v.queue(id);
        if (shares == 0) return;
        vm.prank(owner_);
        v.cancelRequest(id);
    }

    function processQueue(uint256 maxRequests, bool isSenior) external watchSenior {
        calls++;
        queuePaid += _vault(isSenior).processQueue(bound(maxRequests, 1, 8));
        if (isSenior) seniorPaidOut = true;
    }

    // ------------------------------------------------------------ borrowers

    function openLine(uint256 who, uint256 deposit, uint256 multipleBps) external watchSenior {
        calls++;
        address b = borrowers[who % borrowers.length];
        if (manager.activeLine(b) != address(0)) return;
        deposit = bound(deposit, 20e6, 20_000e6);
        uint256 principal = (deposit * bound(multipleBps, 0, 30_000)) / 10_000;
        if (principal > pool.idle()) return;
        vm.prank(underwriter);
        manager.approve(b, uint128(principal == 0 ? 1 : principal), 1_500, uint40(block.timestamp + 1 days));
        ausd.mint(b, deposit);
        vm.startPrank(b);
        ausd.approve(address(manager), deposit);
        try manager.openLine(deposit, principal) returns (address line) {
            lines.push(CreditLine(line));
            fundedPrincipal[line] = principal;
            opened++;
        } catch {}
        vm.stopPrank();
    }

    function setScores(uint256[] calldata accounts, uint256[] calldata epochs, ScoreRules.Features calldata f) external {
        scoreAccount = accounts;
        scoreEpoch = epochs;
        _scoreFeatures = f;
    }

    /// Open a line from the borrower's finalized score leaf instead of an underwriter approval.
    function openScoredLine(uint256 who, uint256 deposit, uint256 multipleBps) external watchSenior {
        calls++;
        if (scoreAccount.length == 0) return;
        uint256 i = who % borrowers.length;
        address b = borrowers[i];
        if (manager.activeLine(b) != address(0)) return;
        ScoreRules.Features memory f = _scoreFeatures;
        uint256 limit = ScoreRules.limitFor(f);
        deposit = bound(deposit, 20e6, 20_000e6);
        uint256 principal = (deposit * bound(multipleBps, 0, 30_000)) / 10_000;
        if (principal > limit) principal = limit;
        if (principal > pool.idle()) return;
        ausd.mint(b, deposit);
        vm.startPrank(b);
        ausd.approve(address(manager), deposit);
        try manager.openLineWithScore(
            deposit, principal, scoreEpoch[i], scoreAccount[i], f, limit, ScoreRules.aprFor(f), new bytes32[](0)
        ) returns (address line) {
            lines.push(CreditLine(line));
            fundedPrincipal[line] = principal;
            opened++;
            scoredOpened++;
        } catch {}
        vm.stopPrank();
    }

    function trade(uint256 lineSeed, uint256 lot, uint256 lev, bool isLong, bool isClose) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        uint256 m = ex.mark(BTC);
        lev = bound(lev, 100, 300);
        // Size opens to what the line can actually afford (notional CNS = price * lot in the mock),
        // so the fuzzer spends its budget on real positions instead of rejected oversized orders.
        uint256 maxLot = (line.equity() * lev) / 100 / m;
        if (maxLot == 0) maxLot = 1;
        uint8 t = isClose ? (isLong ? 2 : 3) : (isLong ? 0 : 1);
        IExchange.OrderDesc[] memory o = new IExchange.OrderDesc[](1);
        o[0].perpId = BTC;
        o[0].orderType = IExchange.OrderDescEnum.wrap(t);
        bool buys = t == 0 || t == 3;
        o[0].pricePNS = buys ? (m * 10_040) / 10_000 : (m * 9_960) / 10_000;
        o[0].lotLNS = isClose ? bound(lot, 1, type(uint64).max) : bound(lot, 1, (maxLot * 9) / 10 + 1);
        o[0].immediateOrCancel = true;
        o[0].leverageHdths = lev;
        address b = line.borrower();
        vm.prank(b);
        try line.trade(o) {
            trades++;
        } catch {}
    }

    function sweep(uint256 lineSeed, uint256 amount) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        address b = line.borrower();
        amount = bound(amount, 1, 50_000e6);
        IdentityRegistry.Proof memory p = _proof(identity, _pk(b), b, address(line), keccak256(abi.encode("sweep", amount)));
        vm.prank(b);
        try line.sweep(amount, p) {
            sweeps++;
        } catch {}
    }

    function repay(uint256 lineSeed, uint256 amount) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        address b = line.borrower();
        amount = bound(amount, 1, 50_000e6);
        ausd.mint(b, amount);
        vm.startPrank(b);
        ausd.approve(address(line), amount);
        try line.repay(amount) {} catch {}
        vm.stopPrank();
    }

    function topUp(uint256 lineSeed, uint256 amount) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        address b = line.borrower();
        amount = bound(amount, 1, 10_000e6);
        ausd.mint(b, amount);
        vm.startPrank(b);
        ausd.approve(address(line), amount);
        try line.topUp(amount) {} catch {}
        vm.stopPrank();
    }

    function borrowerClose(uint256 lineSeed) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        _recordedClose(line, true);
    }

    /// @notice Borrower grants a session key with a passkey approval; the key trades within its caps.
    function sessionTrade(uint256 lineSeed, uint256 lot, uint96 maxOrder, uint96 total) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0) || line.state() != CreditLine.State.Active) return;
        address b = line.borrower();
        uint40 expiry = uint40(block.timestamp + 1 days);
        maxOrder = uint96(bound(maxOrder, 1e6, 50_000e6));
        total = uint96(bound(total, maxOrder, 100_000e6));
        IdentityRegistry.Proof memory p = _proof(
            identity, _pk(b), b, address(line), keccak256(abi.encode("grantSession", sessionKey, expiry, maxOrder, total))
        );
        vm.prank(b);
        try line.grantSession(sessionKey, expiry, maxOrder, total, p) {
            sessionsGranted++;
        } catch {
            return;
        }
        uint256 m = ex.mark(BTC);
        IExchange.OrderDesc[] memory o = new IExchange.OrderDesc[](1);
        o[0].perpId = BTC;
        o[0].orderType = IExchange.OrderDescEnum.wrap(0);
        o[0].pricePNS = (m * 10_040) / 10_000;
        o[0].lotLNS = bound(lot, 1, 20_000);
        o[0].immediateOrCancel = true;
        o[0].leverageHdths = 200;
        vm.prank(sessionKey);
        try line.trade(o) {
            sessionTrades++;
        } catch {}
    }

    /// @notice A session key tries every way to move money out. None may succeed.
    function sessionAttack(uint256 lineSeed, uint256 amount) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        amount = bound(amount, 1, 50_000e6);
        IdentityRegistry.Proof memory none;
        vm.startPrank(sessionKey);
        try line.sweep(amount, none) {
            sessionExtractions++;
        } catch {}
        try line.close(none) {
            sessionExtractions++;
        } catch {}
        try line.repayFromAccount(amount) {
            sessionExtractions++;
        } catch {}
        try line.grantSession(makeAddr("inv-session-2"), uint40(block.timestamp + 1 hours), 1e6, 1e6, none) {
            sessionExtractions++;
        } catch {}
        vm.stopPrank();
    }

    // ------------------------------------------------------------ circuit breaker

    function togglePause(bool on) external watchSenior {
        calls++;
        vm.prank(breakerOwner);
        if (on) breaker.pause();
        else breaker.unpause();
    }

    function toggleVenuePause(bool on) external watchSenior {
        calls++;
        ex.setPaused(BTC, on);
    }

    // ------------------------------------------------------------ market, time, venue

    function moveMark(uint256 pctBps, bool up) external watchSenior {
        calls++;
        uint256 m = ex.mark(BTC);
        uint256 d = (m * bound(pctBps, 0, 3_000)) / 10_000;
        uint256 next = up ? m + d : (m > d + 1_000 ? m - d : 1_000);
        ex.setMark(BTC, next);
    }

    function passTime(uint256 secs) external watchSenior {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
        ex.setMark(BTC, ex.mark(BTC)); // keep the mark fresh
    }

    function venueLiquidate(uint256 lineSeed) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        ex.liquidate(BTC, line.account().accountId());
    }

    /// @notice A violent move (20 to 70 percent either way), then keepers try to enforce on every
    ///         open line. This is the path that decides whether lenders get hurt.
    function crashAndEnforce(uint256 pctBps, bool up) external watchSenior {
        calls++;
        uint256 m = ex.mark(BTC);
        uint256 d = (m * bound(pctBps, 2_000, 7_000)) / 10_000;
        ex.setMark(BTC, up ? m + d : m - d);
        for (uint256 i; i < lines.length; ++i) {
            CreditLine line = lines[i];
            if (line.state() == CreditLine.State.Active) {
                vm.prank(keeper);
                try line.freeze() {
                    frozen++;
                    _noteBounty(line);
                } catch {}
            }
            if (line.state() == CreditLine.State.Frozen) {
                vm.prank(keeper);
                try line.unwind(BTC, type(uint256).max) {
                    unwinds++;
                } catch {}
                _recordedClose(line, false);
            }
        }
    }

    // ------------------------------------------------------------ keepers

    function keeperFreeze(uint256 lineSeed) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        vm.prank(keeper);
        try line.freeze() {
            frozen++;
            _noteBounty(line);
        } catch {}
    }

    function keeperUnwind(uint256 lineSeed) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        vm.prank(keeper);
        try line.unwind(BTC, type(uint256).max) {
            unwinds++;
        } catch {}
    }

    function keeperClose(uint256 lineSeed) external watchSenior {
        calls++;
        CreditLine line = _line(lineSeed);
        if (address(line) == address(0)) return;
        _recordedClose(line, false);
    }

    // ------------------------------------------------------------ helpers

    /// @dev The borrower closes an active line with a passkey approval; a keeper settles a frozen one.
    function _recordedClose(CreditLine line, bool byBorrower) internal {
        uint256 lossesBefore = pool.totalLosses();
        bool ok;
        uint256 keeperBefore = ausd.balanceOf(keeper);
        if (byBorrower) {
            address b = line.borrower();
            IdentityRegistry.Proof memory p = _proof(identity, _pk(b), b, address(line), keccak256("close"));
            vm.prank(b);
            try line.close(p) {
                ok = true;
            } catch {}
        } else {
            vm.prank(keeper);
            try line.settleFrozen() {
                ok = true;
            } catch {}
        }
        if (ok) {
            uint256 loss = pool.totalLosses() - lossesBefore;
            lossOf[address(line)] += loss;
            bountiesPaid += ausd.balanceOf(keeper) - keeperBefore;
            closed++;
            if (loss != 0) closesWithLoss++;
        }
    }

    function _noteBounty(CreditLine line) internal {
        uint256 b = line.bountyOwed();
        if (b > maxBountyObserved) maxBountyObserved = b;
    }

    function _pk(address who) internal pure returns (uint256) {
        return (uint256(keccak256(abi.encode("passkey", who))) % (P256_N - 1)) + 1;
    }

    /// @dev Prefer a line that is still open, so actions are not wasted on closed lines.
    function _line(uint256 seed) internal view returns (CreditLine) {
        uint256 n = lines.length;
        if (n == 0) return CreditLine(address(0));
        for (uint256 k; k < n; ++k) {
            CreditLine l = lines[(seed % n + k) % n];
            CreditLine.State st = l.state();
            if (st == CreditLine.State.Active || st == CreditLine.State.Frozen) return l;
        }
        return lines[seed % n];
    }
}
