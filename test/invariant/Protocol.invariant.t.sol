// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DelegatedAccount} from "perpl-delegated-account/DelegatedAccount.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {Handler} from "./Handler.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {HistoryLinkRegistry} from "../../src/HistoryLinkRegistry.sol";
import {ScoreOracle, IGuardianSource} from "../../src/ScoreOracle.sol";
import {ScoreRules} from "../../src/ScoreRules.sol";
import {MockGuardianSource} from "../mocks/MockGuardianSource.sol";

/// @notice The six safety properties from docs/DESIGN.md, checked after every step of random
///         sequences of lender, borrower, keeper, market and venue actions.
contract ProtocolInvariantTest is StdInvariant, Fixture {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(ausd, ex, pool, senior, junior, manager, underwriter, identity, breaker, admin);
        _setUpScores();
        targetContract(address(handler));
        // Setup-only: the fuzzer must not rewrite the scored accounts.
        bytes4[] memory setupOnly = new bytes4[](1);
        setupOnly[0] = Handler.setScores.selector;
        excludeSelector(FuzzSelector({addr: address(handler), selectors: setupOnly}));
    }

    /// @dev Gives every handler borrower a linked Perpl account and a finalized one-leaf epoch, so
    ///      scored lines go through every invariant below alongside underwriter-approved ones.
    function _setUpScores() internal {
        HistoryLinkRegistry links = new HistoryLinkRegistry(IExchange(address(ex)));
        ScoreOracle oracle =
            new ScoreOracle(admin, IGuardianSource(address(new MockGuardianSource(admin))), admin, 0, 0);
        vm.startPrank(admin);
        manager.setHistoryLinks(links);
        manager.setScoreOracle(oracle);
        oracle.setMaxEpochAge(365 days);
        oracle.setChallengeWindow(1 hours);
        vm.stopPrank();

        ScoreRules.Features memory f = ScoreRules.Features({
            activeDays: 10, closes: 40, pnlExtMicro: 500e6, avgLevBps: 20_000, liqHist: 0,
            washShareBps: 0, washPair: false, maxDepositMicro: 5_000e6
        });
        uint256 n = handler.borrowersLength();
        uint256[] memory accounts = new uint256[](n);
        uint256[] memory epochs = new uint256[](n);
        vm.roll(block.number + 2);
        for (uint256 i; i < n; ++i) {
            epochs[i] = i + 1;
            accounts[i] = _linkAndPropose(links, oracle, handler.borrowers(i), 0xA11CE + i, epochs[i], f);
        }
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < n; ++i) oracle.finalize(epochs[i]);
        handler.setScores(accounts, epochs, f);
    }

    function _linkAndPropose(
        HistoryLinkRegistry links,
        ScoreOracle oracle,
        address borrower,
        uint256 key,
        uint256 epoch,
        ScoreRules.Features memory f
    ) internal returns (uint256 account) {
        address wallet = vm.addr(key);
        ausd.mint(wallet, 100e6);
        vm.startPrank(wallet);
        ausd.approve(address(ex), 100e6);
        account = ex.createAccount(100e6);
        vm.stopPrank();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 h = keccak256(abi.encode(links.LINK_TYPEHASH(), borrower, account, links.nonces(wallet), deadline));
        (uint8 v, bytes32 r, bytes32 sg) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", links.domainSeparator(), h)));
        vm.prank(borrower);
        links.link(account, wallet, deadline, abi.encodePacked(r, sg, v));
        bytes32 leaf = oracle.leafHash(epoch, account, f, ScoreRules.limitFor(f), ScoreRules.aprFor(f));
        vm.prank(admin);
        oracle.propose(epoch, leaf, block.number - 1, "inv");
    }

    /// 1. The pool never loses more on a line than it lent that line.
    function invariant_lossNeverExceedsPrincipal() public view {
        uint256 n = handler.linesLength();
        uint256 lost;
        uint256 lent;
        for (uint256 i; i < n; ++i) {
            address line = address(handler.lines(i));
            assertLe(handler.lossOf(line), handler.fundedPrincipal(line), "line lost more than its principal");
            assertLe(pool.principalOf(line), handler.fundedPrincipal(line), "outstanding above funded");
            lost += handler.lossOf(line);
            lent += handler.fundedPrincipal(line);
        }
        assertEq(pool.totalLosses(), lost, "unattributed pool loss");
        assertLe(lost, lent);
    }

    /// 2. Only the line controls its Perpl account: it is the owner and nobody is an operator.
    function invariant_onlyTheLineControlsItsAccount() public view {
        uint256 n = handler.linesLength();
        for (uint256 i; i < n; ++i) {
            CreditLine line = handler.lines(i);
            DelegatedAccount account = line.account();
            assertEq(account.owner(), address(line), "line lost ownership");
            assertFalse(account.isOperator(line.borrower()), "borrower became an operator");
            assertFalse(account.isOperator(handler.keeper()), "keeper became an operator");
            assertEq(ausd.balanceOf(address(account)), 0, "funds stranded in the account contract");
        }
    }

    /// 2b. Session keys can trade but can never move money out.
    function invariant_sessionKeysNeverExtract() public view {
        assertEq(handler.sessionExtractions(), 0, "a session key moved money out");
        assertEq(ausd.balanceOf(handler.sessionKey()), 0);
    }

    /// 4b. A freeze bounty never exceeds the configured cap.
    function invariant_bountyWithinCap() public view {
        assertLe(handler.maxBountyObserved(), manager.maxFreezeBounty());
    }

    /// 3. Pool accounting adds up: assets equal idle cash plus principal lent, and the outstanding
    ///    total equals the sum of every line's outstanding principal.
    function invariant_poolAccounting() public view {
        uint256 n = handler.linesLength();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += pool.principalOf(address(handler.lines(i)));
        }
        assertEq(pool.principalOutstanding(), sum, "outstanding mismatch");
        assertEq(pool.totalAssets(), ausd.balanceOf(address(pool)) + sum, "totalAssets mismatch");
        // Every dollar the pool holds or has lent belongs to exactly one of senior, junior, reserve.
        assertEq(
            pool.seniorAssets() + pool.juniorAssets() + pool.reserve(),
            ausd.balanceOf(address(pool)) + sum,
            "tranche claims do not match pool assets"
        );
        assertEq(senior.totalAssets(), pool.seniorAssets());
        assertEq(junior.totalAssets(), pool.juniorAssets());
    }

    /// 3b. Tranche vaults never hold cash (it all sits in the pool), and escrowed queue shares are
    ///     exactly the unpaid requests.
    function invariant_vaultsHoldNoCashAndQueueBalances() public view {
        assertEq(ausd.balanceOf(address(senior)), 0);
        assertEq(ausd.balanceOf(address(junior)), 0);
        assertEq(senior.balanceOf(address(senior)), senior.queuedShares());
        assertEq(junior.balanceOf(address(junior)), junior.queuedShares());
    }

    /// 3c. Loss order: senior is touched only after the reserve and all of junior are gone.
    function invariant_seniorProtectedByJunior() public view {
        assertEq(handler.seniorLossesWithCushion(), 0, "senior lost value while junior or the reserve had funds");
    }

    /// 4. A borrower has at most one open line, and the registry points at it.
    function invariant_oneOpenLinePerBorrower() public view {
        uint256 nb = handler.borrowersLength();
        uint256 nl = handler.linesLength();
        for (uint256 b; b < nb; ++b) {
            address borrower = handler.borrowers(b);
            uint256 open;
            address openLine;
            for (uint256 i; i < nl; ++i) {
                CreditLine line = handler.lines(i);
                if (line.borrower() != borrower) continue;
                CreditLine.State s = line.state();
                if (s == CreditLine.State.Active || s == CreditLine.State.Frozen) {
                    open++;
                    openLine = address(line);
                }
            }
            assertLe(open, 1, "more than one open line");
            assertEq(manager.activeLine(borrower), openLine, "registry out of sync");
        }
    }

    /// 5. Any active line below the freeze threshold can be frozen by anyone.
    function invariant_unhealthyLinesCanAlwaysBeFrozen() public {
        uint256 n = handler.linesLength();
        uint16 threshold = manager.riskParams().freezeHealthBps;
        for (uint256 i; i < n; ++i) {
            CreditLine line = handler.lines(i);
            if (line.state() != CreditLine.State.Active || line.healthBps() >= threshold) continue;
            uint256 snap = vm.snapshotState();
            vm.prank(makeAddr("anyone"));
            line.freeze(); // must not revert
            assertEq(uint8(line.state()), uint8(CreditLine.State.Frozen));
            vm.revertToState(snap);
        }
    }

    /// 6. No admin or underwriter path moves funds to them, and no AUSD leaks to an untracked
    ///    address: total supply equals the sum over every known holder.
    function invariant_noFundsLeakToAdminsOrStrangers() public view {
        assertEq(ausd.balanceOf(admin), 0);
        assertEq(ausd.balanceOf(underwriter), 0);

        uint256 known = ausd.balanceOf(address(pool)) + ausd.balanceOf(address(ex)) + ausd.balanceOf(lender);
        for (uint256 i; i < 5; ++i) {
            known += ausd.balanceOf(handler.lenders(i)) + ausd.balanceOf(handler.borrowers(i));
        }
        known += ausd.balanceOf(handler.keeper()) + ausd.balanceOf(handler.sessionKey());
        uint256 n = handler.linesLength();
        for (uint256 i; i < n; ++i) {
            CreditLine line = handler.lines(i);
            known += ausd.balanceOf(address(line)) + ausd.balanceOf(address(line.account()));
        }
        assertEq(ausd.totalSupply(), known, "AUSD reached an untracked address");
    }

    /// @dev Appends each run's coverage counts so a summary across all runs can be checked.
    function afterInvariant() public {
        string memory lines_ = string.concat(
            vm.toString(handler.opened()), ",", vm.toString(handler.trades()), ",", vm.toString(handler.sweeps()), ",",
            vm.toString(handler.frozen()), ",", vm.toString(handler.unwinds()), ",", vm.toString(handler.closed()), ","
        );
        string memory rest = string.concat(
            vm.toString(handler.closesWithLoss()), ",", vm.toString(handler.sessionsGranted()), ",",
            vm.toString(handler.sessionTrades()), ",", vm.toString(handler.seniorDeposits()), ","
        );
        string memory tranches = string.concat(
            vm.toString(handler.queuedRequests()), ",", vm.toString(handler.queuePaid()), ",",
            vm.toString(handler.instantWithdrawals()), ",", vm.toString(handler.seniorHits()), ",",
            vm.toString(handler.scoredOpened())
        );
        vm.writeLine("out/invariant-coverage.csv", string.concat(lines_, rest, tranches));
    }
}
