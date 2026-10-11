// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../utils/Fixture.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {TrancheVault} from "../../src/TrancheVault.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @dev The fixture lends 1,000,000 into junior. Tests that need a senior tranche add it on top.
contract CreditPoolTest is Fixture {
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        manager.setMaxLineBps(10_000); // these tests size lines to stress the pool; concentration is tested in Caps
    }

    // ------------------------------------------------------------ access

    function test_onlyRegisteredLinesCanSettle() public {
        vm.prank(alice);
        vm.expectRevert(CreditPool.OnlyLine.selector);
        pool.settle(0, 0, 1);
    }

    function test_lineCannotSettleMoreThanItBorrowed() public {
        CreditLine line = _openLine(alice, 1_000e6, 2_000e6);
        vm.prank(address(line));
        vm.expectRevert(abi.encodeWithSelector(CreditPool.SettlementExceedsPrincipal.selector, 2_000e6 + 1, 2_000e6));
        pool.settle(0, 0, 2_000e6 + 1);
    }

    function test_onlyManagerFunds() public {
        vm.prank(alice);
        vm.expectRevert(CreditPool.OnlyManager.selector);
        pool.fund(alice, 1);
    }

    function test_onlyVaultsMoveTrancheBooks() public {
        vm.startPrank(alice);
        vm.expectRevert(CreditPool.OnlyVault.selector);
        pool.onDeposit(CreditPool.Tranche.Junior, 1);
        vm.expectRevert(CreditPool.OnlyVault.selector);
        pool.onWithdraw(CreditPool.Tranche.Senior, 1, alice);
        vm.stopPrank();
        // A vault cannot act for the other tranche.
        vm.prank(address(junior));
        vm.expectRevert(CreditPool.OnlyVault.selector);
        pool.onWithdraw(CreditPool.Tranche.Senior, 1, alice);
    }

    function test_wiringIsOneShot() public {
        vm.prank(admin);
        vm.expectRevert(CreditPool.AlreadySet.selector);
        pool.wire(alice, alice, alice);
    }

    // ------------------------------------------------------------ liquidity

    function test_withdrawalsLimitedToIdleLiquidity() public {
        _openLine(alice, 100_000e6, 300_000e6); // lends 300k of the 1M pool
        assertEq(pool.idle(), 700_000e6);
        assertEq(pool.totalAssets(), 1_000_000e6);
        assertEq(junior.maxWithdraw(lender), 700_000e6);
        vm.prank(lender);
        vm.expectRevert();
        junior.withdraw(700_000e6 + 1, lender, lender);
        vm.prank(lender);
        junior.withdraw(700_000e6, lender, lender);
        assertEq(pool.juniorAssets(), 300_000e6);
    }

    function test_utilizationCapLimitsLending() public {
        // 90% cap on a 1M pool: a 900,001 loan must fail even though the cash is there.
        _registerPasskey(alice);
        _approve(alice, 900_001e6);
        ausd.mint(alice, 400_000e6);
        vm.startPrank(alice);
        ausd.approve(address(manager), 400_000e6);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.UtilizationCap.selector, 9_000, 9_000)); // 90.0001% floors to 9000
        manager.openLine(400_000e6, 900_001e6);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ subordination

    function test_seniorCannotOutgrowItsJuniorCushion() public {
        // Junior 1M at a 20% floor supports at most 4M of senior.
        assertEq(senior.maxDeposit(bob), 4_000_000e6);
        _lendTo(senior, bob, 4_000_000e6);
        assertEq(pool.juniorBps(), 2_000);
        assertEq(senior.maxDeposit(bob), 0);

        ausd.mint(bob, 1e6);
        vm.startPrank(bob);
        ausd.approve(address(senior), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1e6, 0));
        senior.deposit(1e6, bob);
        vm.stopPrank();

        // The pool enforces the floor itself too, not only the vault's maxDeposit.
        vm.prank(address(senior));
        vm.expectRevert(abi.encodeWithSelector(CreditPool.JuniorBelowMinimum.selector, 1_999, 2_000));
        pool.onDeposit(CreditPool.Tranche.Senior, 1e6);
    }

    function test_juniorCannotWithdrawBelowFloor() public {
        _lendTo(senior, bob, 2_000_000e6);
        // Senior 2M needs junior >= 2M * 20 / 80 = 500k, so only 500k of junior is free.
        assertEq(pool.withdrawable(CreditPool.Tranche.Junior), 500_000e6);
        assertEq(junior.maxWithdraw(lender), 500_000e6);
        vm.prank(lender);
        vm.expectRevert();
        junior.withdraw(500_000e6 + 1, lender, lender);
        vm.prank(lender);
        junior.withdraw(500_000e6, lender, lender);
        assertEq(pool.juniorBps(), 2_000);
        // Senior is not held back by the floor.
        assertEq(senior.maxWithdraw(bob), 2_000_000e6);
    }

    // ------------------------------------------------------------ waterfalls (hand calculated)

    /// Senior 4M, junior 1M. A line borrows 1M and pays 100,000 interest after one year.
    ///   senior target: 8% on senior's 80% share of the 1M deployed = 64,000
    ///   reserve:       10% of 100,000                              = 10,000
    ///   senior:        min(90,000, 64,000)                          = 64,000
    ///   junior:        90,000 - 64,000                              = 26,000
    function test_interestWaterfall() public {
        _lendTo(senior, bob, 4_000_000e6);
        CreditLine line = _openLine(alice, 400_000e6, 1_000_000e6);
        vm.warp(block.timestamp + 365 days);
        _payInterest(line, 100_000e6);

        assertEq(pool.reserve(), 10_000e6);
        assertEq(pool.seniorAssets(), 4_064_000e6);
        assertEq(pool.juniorAssets(), 1_026_000e6);
        assertEq(pool.seniorShortfall(), 0);
    }

    /// When interest falls short of the senior target, senior takes all of it (after reserve) and
    /// the rest stays owed, ahead of junior, out of later interest.
    function test_seniorShortfallCarriesForward() public {
        _lendTo(senior, bob, 4_000_000e6);
        CreditLine line = _openLine(alice, 400_000e6, 1_000_000e6);
        vm.warp(block.timestamp + 365 days);
        _payInterest(line, 50_000e6); // reserve 5,000; senior 45,000 of its 64,000; junior nothing
        assertEq(pool.seniorAssets(), 4_045_000e6);
        assertEq(pool.juniorAssets(), 1_000_000e6);
        assertEq(pool.seniorShortfall(), 19_000e6);

        _payInterest(line, 30_000e6); // reserve 3,000; senior 19,000; junior 8,000
        assertEq(pool.seniorAssets(), 4_064_000e6);
        assertEq(pool.juniorAssets(), 1_008_000e6);
        assertEq(pool.reserve(), 8_000e6);
        assertEq(pool.seniorShortfall(), 0);
    }

    function test_seniorTargetDoesNotAccrueOnIdleCash() public {
        _lendTo(senior, bob, 4_000_000e6);
        vm.warp(block.timestamp + 365 days);
        _lendTo(junior, carol, 1e6); // any pool action accrues
        assertEq(pool.seniorShortfall(), 0);
    }

    /// Reserve 10,000, junior 1,026,000, senior 4,064,000 (from the interest test). A 1M loss:
    ///   reserve absorbs 10,000; junior absorbs 990,000; senior untouched.
    /// A further loss larger than what junior has left reaches senior only for the remainder.
    function test_lossWaterfall() public {
        _lendTo(senior, bob, 4_000_000e6);
        CreditLine line = _openLine(alice, 400_000e6, 1_000_000e6);
        vm.warp(block.timestamp + 365 days);
        _payInterest(line, 100_000e6);

        vm.prank(address(line));
        pool.settle(0, 0, 1_000_000e6);
        assertEq(pool.reserve(), 0);
        assertEq(pool.juniorAssets(), 36_000e6);
        assertEq(pool.seniorAssets(), 4_064_000e6, "senior untouched while junior had assets");

        CreditLine line2 = _openLine(carol, 100_000e6, 100_000e6);
        vm.prank(address(line2));
        pool.settle(0, 0, 100_000e6);
        assertEq(pool.juniorAssets(), 0);
        assertEq(pool.seniorAssets(), 4_000_000e6, "senior takes only 64,000 past junior");
        assertEq(pool.totalLosses(), 1_100_000e6);
    }

    function test_lossesMoveSharePrices() public {
        _lendTo(senior, bob, 4_000_000e6);
        CreditLine line = _openLine(alice, 400_000e6, 500_000e6);
        uint256 juniorBefore = junior.previewRedeem(junior.balanceOf(lender));
        vm.prank(address(line));
        pool.settle(0, 0, 500_000e6);
        assertEq(junior.previewRedeem(junior.balanceOf(lender)), juniorBefore - 500_000e6);
        assertApproxEqAbs(senior.previewRedeem(senior.balanceOf(bob)), 4_000_000e6, 1, "senior share value unchanged");
    }

    /// Any mix of tranche sizes, reserve and loss: the reserve pays first, then junior, and senior
    /// pays only the remainder once both are empty. Nothing is created or destroyed.
    function testFuzz_lossWaterfallOrder(uint256 seniorAmt, uint256 juniorExtra, uint256 interest, uint256 loss)
        public
    {
        seniorAmt = bound(seniorAmt, 0, 4_000_000e6); // fixture junior 1M supports up to 4M senior
        juniorExtra = bound(juniorExtra, 0, 1_000_000e6);
        if (seniorAmt != 0) _lendTo(senior, bob, seniorAmt);
        if (juniorExtra != 0) _lend(carol, juniorExtra);

        uint256 total = pool.seniorAssets() + pool.juniorAssets();
        uint256 principal = (total * 9) / 10;
        CreditLine line = _openLine(alice, principal, principal);
        interest = bound(interest, 0, 200_000e6);
        if (interest != 0) _payInterest(line, interest);

        uint256 r0 = pool.reserve();
        uint256 j0 = pool.juniorAssets();
        uint256 s0 = pool.seniorAssets();
        loss = bound(loss, 1, principal);
        vm.prank(address(line));
        pool.settle(0, 0, loss);

        uint256 fromReserve = r0 - pool.reserve();
        uint256 fromJunior = j0 - pool.juniorAssets();
        uint256 fromSenior = s0 - pool.seniorAssets();
        assertEq(fromReserve + fromJunior + fromSenior, loss, "loss not fully allocated");
        assertEq(fromReserve, loss < r0 ? loss : r0, "reserve did not pay first");
        if (fromJunior != 0) assertEq(pool.reserve(), 0, "junior paid while reserve had funds");
        if (fromSenior != 0) {
            assertEq(pool.reserve(), 0, "senior paid while reserve had funds");
            assertEq(pool.juniorAssets(), 0, "senior paid while junior had funds");
        }
    }

    // ------------------------------------------------------------ withdrawal queue

    function test_queuePaysInOrderAsLiquidityReturns() public {
        _lendTo(junior, bob, 1_000_000e6); // junior 2M: lender 1M, bob 1M
        CreditLine line = _openLine(alice, 600_000e6, 1_800_000e6); // 90% lent, 200k idle
        uint256 lenderShares = junior.balanceOf(lender);
        uint256 bobShares = junior.balanceOf(bob);

        vm.prank(lender);
        uint256 first = junior.requestRedeem(lenderShares);
        vm.prank(bob);
        uint256 second = junior.requestRedeem(bobShares);
        assertEq(junior.balanceOf(address(junior)), lenderShares + bobShares);

        assertEq(junior.processQueue(10), 0, "200k idle cannot pay a 1M request");
        assertEq(junior.head(), first);

        _repay(line, 1_000_000e6); // 1.2M idle now
        assertEq(junior.processQueue(10), 1);
        assertApproxEqAbs(ausd.balanceOf(lender), 1_000_000e6, 1);
        assertEq(junior.head(), second, "bob still waits");

        _repay(line, 800_000e6);
        assertEq(junior.processQueue(10), 1);
        assertApproxEqAbs(ausd.balanceOf(bob), 1_000_000e6, 1);
        assertEq(junior.queuedShares(), 0);
    }

    function test_instantWithdrawalCannotJumpTheQueue() public {
        _lendTo(junior, bob, 1_000_000e6);
        _openLine(alice, 600_000e6, 1_500_000e6); // 500k idle
        uint256 half = junior.balanceOf(lender) / 2;
        vm.prank(lender);
        junior.requestRedeem(half); // ~500k owed to the queue
        assertLe(junior.maxWithdraw(bob), 1, "queued liquidity is not available to bob");
        vm.prank(bob);
        vm.expectRevert();
        junior.withdraw(1_000e6, bob, bob);
    }

    function test_cancelReturnsShares() public {
        uint256 shares = junior.balanceOf(lender);
        vm.prank(lender);
        uint256 id = junior.requestRedeem(shares);
        vm.prank(bob);
        vm.expectRevert(TrancheVault.NotRequestOwner.selector);
        junior.cancelRequest(id);
        vm.prank(lender);
        junior.cancelRequest(id);
        assertEq(junior.balanceOf(lender), shares);
        assertEq(junior.queuedShares(), 0);
        vm.prank(lender);
        vm.expectRevert(TrancheVault.AlreadyProcessed.selector);
        junior.cancelRequest(id);
    }

    function test_queuedSharesStillBearLosses() public {
        CreditLine line = _openLine(alice, 400_000e6, 1_000_000e6 * 9 / 10);
        uint256 all = junior.balanceOf(lender);
        vm.prank(lender);
        junior.requestRedeem(all);
        vm.prank(address(line));
        pool.settle(0, 0, 400_000e6);
        // 1M of junior lost 400k; the queued request is now worth 600k, not 1M.
        assertApproxEqAbs(junior.previewRedeem(junior.queuedShares()), 600_000e6, 1);
    }

    // ------------------------------------------------------------ share safety

    /// @notice First-depositor inflation attack against a fresh tranche vault: the attacker mints
    ///         dust shares and donates to inflate the price. Donations go to the pool, not the
    ///         vault's books, and the virtual-share offset makes rounding theft unprofitable.
    function test_inflationAttackIsUnprofitable() public {
        CreditPool fresh = new CreditPool(ausd, admin);
        TrancheVault j = new TrancheVault(fresh, CreditPool.Tranche.Junior, "J", "J");
        TrancheVault s = new TrancheVault(fresh, CreditPool.Tranche.Senior, "S", "S");
        vm.prank(admin);
        fresh.wire(address(manager), address(s), address(j));

        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        ausd.mint(attacker, 1_000_001e6);
        ausd.mint(victim, 1_000e6);

        vm.startPrank(attacker);
        ausd.approve(address(j), type(uint256).max);
        j.deposit(1, attacker);
        ausd.transfer(address(j), 500_000e6); // donation to the vault
        ausd.transfer(address(fresh), 500_000e6); // donation to the pool
        vm.stopPrank();

        vm.startPrank(victim);
        ausd.approve(address(j), 1_000e6);
        uint256 shares = j.deposit(1_000e6, victim);
        vm.stopPrank();
        assertGt(shares, 0, "victim must receive shares");
        assertApproxEqAbs(j.previewRedeem(shares), 1_000e6, 1, "victim keeps their deposit");

        uint256 attackerShares = j.balanceOf(attacker);
        vm.prank(attacker);
        uint256 attackerOut = j.redeem(attackerShares, attacker, attacker);
        assertLe(attackerOut, 1, "attacker gets back nothing beyond their dust");
    }

    // ------------------------------------------------------------ helpers

    /// @dev A line pays `interest` to the pool directly, as its settlement path does.
    function _payInterest(CreditLine line, uint256 interest) internal {
        ausd.mint(address(line), interest);
        vm.startPrank(address(line));
        ausd.approve(address(pool), interest);
        pool.settle(0, interest, 0);
        vm.stopPrank();
    }

    function _repay(CreditLine line, uint256 principal) internal {
        ausd.mint(address(line), principal);
        vm.startPrank(address(line));
        ausd.approve(address(pool), principal);
        pool.settle(principal, 0, 0);
        vm.stopPrank();
    }
}
