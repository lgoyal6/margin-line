// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IExchange} from "perpl-interfaces/IExchange.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";

/// @notice Session keys: a short-lived key that can trade within caps and can do nothing else.
contract SessionsTest is Fixture {
    CreditLine line;
    address session = makeAddr("session-key");

    function setUp() public override {
        super.setUp();
        line = _openLine(alice, 1_000e6, 2_000e6);
    }

    function _grant(uint40 expiry, uint96 maxOrder, uint96 total) internal {
        IdentityRegistry.Proof memory p =
            _lineProof(line, keccak256(abi.encode("grantSession", session, expiry, maxOrder, total)));
        vm.prank(alice);
        line.grantSession(session, expiry, maxOrder, total, p);
    }

    function _sessionLong(uint256 lot) internal {
        IExchange.OrderDesc[] memory o = _order(0, (ex.mark(BTC) * 10_040) / 10_000, lot, 200);
        vm.prank(session);
        line.trade(o);
    }

    function test_sessionTradesWithinCaps() public {
        _grant(uint40(block.timestamp + 1 days), 600e6, 1_000e6);
        _sessionLong(500); // about $502 at the limit price
        (IExchange.PositionInfoV2 memory pos,,) = ex.getPositionV2(BTC, line.account().accountId());
        assertEq(pos.lotLNS, 500);
        (,, uint96 remaining) = line.sessions(session);
        assertLt(remaining, 1_000e6 - 500e6);
    }

    function test_sessionPerOrderCap() public {
        _grant(uint40(block.timestamp + 1 days), 300e6, 1_000e6);
        IExchange.OrderDesc[] memory o = _order(0, (ex.mark(BTC) * 10_040) / 10_000, 500, 200);
        vm.prank(session);
        vm.expectRevert();
        line.trade(o);
    }

    function test_sessionTotalBudget() public {
        _grant(uint40(block.timestamp + 1 days), 600e6, 700e6);
        _sessionLong(500);
        IExchange.OrderDesc[] memory o = _order(0, (ex.mark(BTC) * 10_040) / 10_000, 500, 200);
        vm.prank(session);
        vm.expectRevert();
        line.trade(o); // budget left is about $198
    }

    function test_sessionCanAlwaysCloseEvenWithBudgetSpent() public {
        _grant(uint40(block.timestamp + 1 days), 600e6, 600e6);
        _sessionLong(500);
        IExchange.OrderDesc[] memory o = _order(2, (ex.mark(BTC) * 9_960) / 10_000, 500, 100);
        vm.prank(session);
        line.trade(o);
    }

    function test_sessionExpires() public {
        _grant(uint40(block.timestamp + 1 hours), 600e6, 1_000e6);
        vm.warp(block.timestamp + 1 hours + 1);
        ex.setMark(BTC, BTC_PRICE);
        IExchange.OrderDesc[] memory o = _order(0, (BTC_PRICE * 10_040) / 10_000, 100, 200);
        vm.prank(session);
        vm.expectRevert(CreditLine.SessionExpired.selector);
        line.trade(o);
    }

    /// @notice Phase 3 exit test: a scoped session key cannot move money out.
    function test_sessionKeyCannotSweepCloseRepayFromAccountOrGrant() public {
        _grant(uint40(block.timestamp + 1 days), 600e6, 1_000e6);
        IdentityRegistry.Proof memory any = _lineProof(line, keccak256(abi.encode("sweep", uint256(100e6))));

        vm.startPrank(session);
        vm.expectRevert(CreditLine.OnlyBorrower.selector);
        line.sweep(100e6, any);
        vm.expectRevert(CreditLine.OnlyBorrower.selector);
        line.close(any);
        vm.expectRevert(CreditLine.OnlyBorrower.selector);
        line.repayFromAccount(100e6);
        vm.expectRevert(CreditLine.OnlyBorrower.selector);
        line.grantSession(makeAddr("another"), uint40(block.timestamp + 1 hours), 1e6, 1e6, any);
        vm.stopPrank();
        assertEq(ausd.balanceOf(session), 0);
    }

    function test_grantNeedsAFreshPasskeyApprovalOfTheExactLimits() public {
        uint40 expiry = uint40(block.timestamp + 1 days);
        // Approval was for a $600 budget; the call asks for $60,000.
        IdentityRegistry.Proof memory p =
            _lineProof(line, keccak256(abi.encode("grantSession", session, expiry, uint96(600e6), uint96(600e6))));
        vm.prank(alice);
        vm.expectRevert(IdentityRegistry.InvalidAssertion.selector);
        line.grantSession(session, expiry, 600e6, 60_000e6, p);
    }

    function test_sweepNeedsApprovalOfTheExactAmount() public {
        IdentityRegistry.Proof memory p = _lineProof(line, keccak256(abi.encode("sweep", uint256(10e6))));
        vm.prank(alice);
        vm.expectRevert(IdentityRegistry.InvalidAssertion.selector);
        line.sweep(400e6, p); // approved 10, asked 400
    }

    function test_sessionLimits() public {
        IdentityRegistry.Proof memory p;
        vm.startPrank(alice);
        vm.expectRevert(CreditLine.InvalidSession.selector);
        line.grantSession(session, uint40(block.timestamp + 8 days), 1e6, 1e6, p); // longer than 7 days
        vm.expectRevert(CreditLine.InvalidSession.selector);
        line.grantSession(alice, uint40(block.timestamp + 1 days), 1e6, 1e6, p); // borrower as session
        vm.expectRevert(CreditLine.InvalidSession.selector);
        line.grantSession(session, uint40(block.timestamp + 1 days), 2e6, 1e6, p); // total below per-order
        vm.stopPrank();
    }

    function test_revokeByBorrowerOrByTheKey() public {
        _grant(uint40(block.timestamp + 1 days), 600e6, 1_000e6);
        vm.prank(session);
        line.revokeSession(session);
        IExchange.OrderDesc[] memory o = _order(0, (BTC_PRICE * 10_040) / 10_000, 100, 200);
        vm.prank(session);
        vm.expectRevert(CreditLine.NotAuthorized.selector);
        line.trade(o);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(CreditLine.NotAuthorized.selector);
        line.revokeSession(session);
    }
}
