// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccount} from "perpl-delegated-account/DelegatedAccount.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {TradeGuard} from "../../src/TradeGuard.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";

contract CreditLineTest is Fixture {
    uint256 constant DEPOSIT = 1_000e6;
    uint256 constant PRINCIPAL = 2_000e6;

    // ------------------------------------------------------------ opening

    function test_open_contractOwnsPerplAccountAndBorrowerIsNotOperator() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        DelegatedAccount account = line.account();
        assertEq(account.owner(), address(line));
        assertFalse(account.isOperator(alice));
        assertEq(ex.balance(account.accountId()), DEPOSIT + PRINCIPAL);
        assertEq(pool.principalOf(address(line)), PRINCIPAL);
        assertEq(manager.activeLine(alice), address(line));
        (uint128 limit,,) = manager.approvals(alice);
        assertEq(limit, 0, "approval must be single use");
        assertEq(uint8(line.state()), uint8(CreditLine.State.Active));
    }

    function test_open_requiresPasskey() public {
        _approve(alice, uint128(PRINCIPAL));
        ausd.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        ausd.approve(address(manager), DEPOSIT);
        vm.expectRevert(CreditManager.PasskeyRequired.selector);
        manager.openLine(DEPOSIT, PRINCIPAL);
        vm.stopPrank();
    }

    function test_open_requiresFirstLossDeposit() public {
        _registerPasskey(alice);
        _approve(alice, uint128(3_001e6));
        ausd.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        ausd.approve(address(manager), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.DepositTooSmall.selector, 3_001e6, DEPOSIT));
        manager.openLine(DEPOSIT, 3_001e6); // more than 3x the deposit
        vm.stopPrank();
    }

    function test_open_rejectsAboveLimitAndExpiredApproval() public {
        _registerPasskey(alice);
        _approve(alice, uint128(PRINCIPAL));
        ausd.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        ausd.approve(address(manager), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.AboveLimit.selector, PRINCIPAL + 1, PRINCIPAL));
        manager.openLine(DEPOSIT, PRINCIPAL + 1);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(CreditManager.ApprovalExpired.selector);
        manager.openLine(DEPOSIT, PRINCIPAL);
        vm.stopPrank();
    }

    function test_open_oneActiveLinePerBorrower() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _approve(alice, uint128(PRINCIPAL));
        ausd.mint(alice, DEPOSIT);
        vm.startPrank(alice);
        ausd.approve(address(manager), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.LineAlreadyOpen.selector, address(line)));
        manager.openLine(DEPOSIT, PRINCIPAL);
        vm.stopPrank();
    }

    function test_initialize_onlyManagerAndOnce() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        vm.expectRevert();
        line.initialize(alice, 1, 1, 1);
        vm.expectRevert();
        lineImpl.initialize(alice, 1, 1, 1); // implementation is locked
    }

    // ------------------------------------------------------------ custody boundary

    function test_borrowerCannotWithdrawOrTradeAroundTheLine() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        DelegatedAccount account = line.account();
        vm.startPrank(alice);
        vm.expectRevert();
        account.withdrawCollateral(1e6);
        vm.expectRevert(DelegatedAccount.OnlyOwnerOrOperator.selector);
        (bool ok,) = address(account).call(abi.encodeCall(IExchange.withdrawCollateral, (1e6)));
        ok;
        vm.stopPrank();
    }

    function test_onlyBorrowerTrades() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        IExchange.OrderDesc[] memory o = _order(0, (BTC_PRICE * 10_040) / 10_000, 100, 200);
        vm.prank(keeper);
        vm.expectRevert(CreditLine.NotAuthorized.selector); // not the borrower and no session key
        line.trade(o);
    }

    // ------------------------------------------------------------ trade rules

    function test_trade_opensAndClosesAndStaysHealthy() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 2_000, 200); // $2,000 notional at 2x
        (IExchange.PositionInfoV2 memory pos,,) = ex.getPositionV2(BTC, line.account().accountId());
        assertEq(pos.lotLNS, 2_000);
        assertGt(line.healthBps(), 14_900); // about 1.50 minus fee and spread
        _closeLong(line, 2_000);
        (pos,,) = ex.getPositionV2(BTC, line.account().accountId());
        assertEq(pos.lotLNS, 0);
    }

    function test_trade_rejectsBuyAboveBandAndSellBelowBand() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        uint256 high = (BTC_PRICE * 10_060) / 10_000; // 0.60% above mark, band is 0.50%
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.PriceOutsideBand.selector, high, BTC_PRICE, uint16(50)));
        line.trade(_order(0, high, 100, 200));

        _long(line, 1_000, 200);
        uint256 low = (BTC_PRICE * 9_900) / 10_000; // a colluder's bid 1% under mark
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.PriceOutsideBand.selector, low, BTC_PRICE, uint16(50)));
        line.trade(_order(2, low, 1_000, 100));
    }

    function test_trade_rejectsEachDisallowedShape() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        uint256 px = (BTC_PRICE * 10_040) / 10_000;
        IExchange.OrderDesc[] memory o;

        o = _order(0, px, 100, 400);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.LeverageTooHigh.selector, 400, 300));
        line.trade(o);

        o = _order(0, px, 100, 200);
        o[0].immediateOrCancel = false;
        vm.prank(alice);
        vm.expectRevert(TradeGuard.MustBeImmediateOrCancel.selector);
        line.trade(o);

        o = _order(0, px, 100, 200);
        o[0].postOnly = true;
        vm.prank(alice);
        vm.expectRevert(TradeGuard.MustBeImmediateOrCancel.selector);
        line.trade(o);

        o = _order(0, px, 100, 200);
        o[0].amountCNS = 1;
        vm.prank(alice);
        vm.expectRevert(TradeGuard.CollateralMoveNotAllowed.selector);
        line.trade(o);

        o = _order(4, px, 100, 200);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.OrderTypeNotAllowed.selector, 4));
        line.trade(o);

        o = _order(0, px, 100, 200);
        o[0].perpId = 2;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.MarketNotAllowed.selector, 2));
        line.trade(o);
    }

    function test_trade_rejectsStaleMark() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        vm.warp(block.timestamp + 121);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.StaleMark.selector, block.timestamp - 121));
        line.trade(_order(0, (BTC_PRICE * 10_040) / 10_000, 100, 200));
    }

    function test_trade_cannotAddRiskWhenHealthIsLow() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 2_000, 300);
        ex.setMark(BTC, (BTC_PRICE * 6_000) / 10_000); // -40%: equity about 3,000 - 800 = 2,200, health ~1.10
        IExchange.OrderDesc[] memory o = _order(0, (ex.mark(BTC) * 10_040) / 10_000, 100, 200);
        vm.prank(alice);
        vm.expectRevert();
        line.trade(o);
    }

    // ------------------------------------------------------------ sweep, top-up, repay

    function test_sweep_onlyAboveSweepHealth() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        // Equity 3,000, debt 2,000: health 1.50. Sweeping 600 leaves 2,400 / 2,000 = 1.20 < 1.25.
        IdentityRegistry.Proof memory p = _lineProof(line, keccak256(abi.encode("sweep", uint256(600e6))));
        vm.prank(alice);
        vm.expectRevert();
        line.sweep(600e6, p);
        _sweep(line, 400e6); // leaves 1.30
        assertEq(ausd.balanceOf(alice), 400e6);
    }

    /// Profit must not be withdrawn against a price Perpl no longer stands behind: with an open
    /// position, a sweep needs a fresh, valid mark (Slither 8.1 finding: equity ignored validity).
    function test_sweep_refusesStaleMarkWithOpenPosition() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 1_000, 200);
        uint256 markTs = block.timestamp;
        vm.warp(block.timestamp + guard.maxMarkAgeSec() + 1); // Perpl's mark not updated since
        IdentityRegistry.Proof memory p = _lineProof(line, keccak256(abi.encode("sweep", uint256(10e6))));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.StaleMark.selector, markTs));
        line.sweep(10e6, p);
    }

    function test_sweep_refusesInvalidMarkWithOpenPosition() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 1_000, 200);
        ex.setMarkInvalid(BTC, true);
        IdentityRegistry.Proof memory p = _lineProof(line, keccak256(abi.encode("sweep", uint256(10e6))));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.MarkInvalid.selector, BTC));
        line.sweep(10e6, p);
    }

    function test_sweep_withoutPositionsIgnoresMarkAge() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        vm.warp(block.timestamp + guard.maxMarkAgeSec() + 1);
        _sweep(line, 100e6); // nothing is priced, so a stale mark cannot inflate equity
        assertEq(ausd.balanceOf(alice), 100e6);
    }

    function test_topUpAndRepayImproveHealth() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        uint256 h0 = line.healthBps();
        ausd.mint(alice, 1_000e6);
        vm.startPrank(alice);
        ausd.approve(address(line), 1_000e6);
        line.topUp(500e6);
        line.repay(500e6);
        vm.stopPrank();
        assertGt(line.healthBps(), h0);
        assertEq(line.principal(), PRINCIPAL - 500e6);
        assertEq(pool.principalOf(address(line)), PRINCIPAL - 500e6);
    }

    function test_interestAccruesAtApr() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        vm.warp(block.timestamp + 365 days);
        assertApproxEqAbs(line.debt(), PRINCIPAL + PRINCIPAL / 10, 1);
    }

    // ------------------------------------------------------------ freeze, unwind, close

    function test_freeze_revertsWhileHealthy() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        vm.prank(keeper);
        vm.expectRevert();
        line.freeze();
    }

    function test_badDay_strangerFreezesUnwindsAndClosesLenderWhole() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 6_000, 300); // $6,000 notional at 3x: $2,000 margin
        // -15%: the position loses $900, equity about $2,100 against $2,000 debt, health about 1.05.
        // Isolated margin means the position is still worth about $1,100, so an unwind recovers it.
        vm.warp(block.timestamp + 7 days); // a week of interest accrues first
        ex.setMark(BTC, (BTC_PRICE * 8_500) / 10_000);

        vm.startPrank(keeper);
        line.freeze();
        line.unwind(BTC, type(uint256).max);
        line.settleFrozen();
        vm.stopPrank();

        assertEq(uint8(line.state()), uint8(CreditLine.State.Closed));
        assertEq(pool.principalOf(address(line)), 0);
        assertEq(pool.totalLosses(), 0, "deposit absorbed the loss");
        assertGt(pool.totalAssets(), 1_000_000e6, "lender earned interest");
        assertEq(manager.activeLine(alice), address(0));
    }

    function test_borrowerCannotTradeOnceFrozen() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 6_000, 300);
        ex.setMark(BTC, (BTC_PRICE * 8_500) / 10_000);
        vm.prank(keeper);
        line.freeze();
        IExchange.OrderDesc[] memory o = _order(2, (ex.mark(BTC) * 9_960) / 10_000, 6_000, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.WrongState.selector, CreditLine.State.Frozen));
        line.trade(o);
    }

    function test_gapThroughBankruptcy_lossNeverExceedsPrincipal() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 2_900, 100); // nearly all equity as margin at 1x, then a gap no keeper can catch
        ex.setMark(BTC, 1); // price collapses to almost zero in one step
        ex.liquidate(BTC, line.account().accountId());

        vm.startPrank(keeper);
        line.freeze();
        line.settleFrozen();
        vm.stopPrank();

        uint256 lost = pool.totalLosses();
        assertLe(lost, PRINCIPAL, "loss capped at principal");
        assertEq(pool.principalOf(address(line)), 0);
    }

    function test_close_activeLineReturnsEverythingAboveDebt() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _close(line);
        assertEq(pool.principalOf(address(line)), 0);
        assertEq(ausd.balanceOf(alice), DEPOSIT); // no time passed, no interest
    }

    function test_close_blockedWithOpenPositions() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 1_000, 200);
        IdentityRegistry.Proof memory p = _lineProof(line, keccak256("close"));
        vm.prank(alice);
        vm.expectRevert(CreditLine.OpenPositions.selector);
        line.close(p);
    }
}
