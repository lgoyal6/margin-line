// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../utils/Fixture.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {RiskLens} from "../../src/RiskLens.sol";

/// @notice The stress view must agree with a calculation done by hand from the venue's rules.
///
/// Mock venue: fills at mark +/- 5 bps, 4 bps taker fee, margin = notional / leverage.
/// BTC mark $100,000; one lot is $1 of notional at that mark.
///
/// Line A (alice): deposit 1,000 + principal 2,000 = 3,000 free. Long 6,000 lots at 3x.
///   fill 100,050 -> notional 6,003.0000; margin 2,001.0000; fee 2.4012
///   free balance 3,000 - 2,001 - 2.4012 = 996.5988
///   position value = margin 2,001 + pnl (100,000 - 100,050) * 6,000 lots = 2,001 - 3 = 1,998
///   equity now 2,994.5988
///   BTC -40%: delta = -40% * 6,000 = -2,400 -> 1,998 - 2,400 < 0 -> floored at 0
///   equity after 996.5988; bounty 0.5% of 2,000 = 10; interest 0
///   principal recovered 986.5988 -> lost 1,013.4012
///
/// Line B (carol): same funding. Short 3,000 lots at 2x.
///   fill 99,950 -> notional 2,998.5000; margin 1,499.2500; fee 1.1994
///   free 1,499.5506; position 1,499.25 - 1.50 = 1,497.75; equity now 2,997.3006
///   BTC -40%: short gains 40% * 3,000 = 1,200 -> 2,697.75; equity after 4,197.3006; lost 0
contract RiskLensTest is Fixture {
    RiskLens internal lens;
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        lens = new RiskLens();
    }

    function _openAB() internal returns (CreditLine a, CreditLine b) {
        a = _openLine(alice, 1_000e6, 2_000e6);
        b = _openLine(carol, 1_000e6, 2_000e6);
        _long(a, 6_000, 300);
        IExchange.OrderDesc[] memory o = _order(1, (ex.mark(BTC) * 9_960) / 10_000, 3_000, 200);
        vm.prank(carol);
        b.trade(o);
    }

    function _shock(int256 moveBps) internal pure returns (RiskLens.Shock[] memory s) {
        s = new RiskLens.Shock[](1);
        s[0] = RiskLens.Shock(BTC, moveBps);
    }

    function _lines(CreditLine a, CreditLine b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = address(a);
        l[1] = address(b);
    }

    function test_stressMatchesHandCalculation() public {
        (CreditLine a, CreditLine b) = _openAB();
        RiskLens.Result memory r = lens.stress(manager, _lines(a, b), _shock(-4_000));

        assertEq(r.lines[0].equityNow, 2_994.5988e6, "A equity now");
        assertEq(r.lines[0].equityAfter, 996.5988e6, "A equity after");
        assertEq(r.lines[0].principalLost, 1_013.4012e6, "A loss");
        assertEq(r.lines[1].equityNow, 2_997.3006e6, "B equity now");
        assertEq(r.lines[1].equityAfter, 4_197.3006e6, "B equity after");
        assertEq(r.lines[1].principalLost, 0, "B loss");

        assertEq(r.totalLoss, 1_013.4012e6);
        assertEq(r.fromReserve, 0);
        assertEq(r.fromJunior, 1_013.4012e6, "junior absorbs it all");
        assertEq(r.fromSenior, 0);
        assertEq(r.juniorAfter, 1_000_000e6 - 1_013.4012e6);
    }

    /// Same book with a thin junior (500) under a 2,000 senior (exactly the 20% floor): the loss
    /// eats all of junior and 513.4012 of senior.
    function test_stressReachesSeniorWhenJuniorIsThin() public {
        vm.prank(lender);
        junior.withdraw(1_000_000e6 - 500e6, lender, lender);
        _lendTo(senior, makeAddr("bob"), 2_000e6);
        vm.prank(admin);
        manager.setMaxLineBps(10_000);

        CreditLine a = _openLine(alice, 1_000e6, 2_000e6);
        _long(a, 6_000, 300);
        address[] memory l = new address[](1);
        l[0] = address(a);
        RiskLens.Result memory r = lens.stress(manager, l, _shock(-4_000));

        assertEq(r.totalLoss, 1_013.4012e6);
        assertEq(r.fromJunior, 500e6);
        assertEq(r.fromSenior, 513.4012e6);
        assertEq(r.juniorAfter, 0);
        assertEq(r.seniorAfter, 1_486.5988e6);
    }

    /// The lens must predict what actually happens: crash the mark for real, enforce, settle, and
    /// compare the pool's realized loss with the lens's prediction taken just before the crash.
    function test_predictionMatchesRealizedLoss() public {
        CreditLine a = _openLine(alice, 1_000e6, 2_000e6);
        _long(a, 6_000, 300);
        address[] memory l = new address[](1);
        l[0] = address(a);
        RiskLens.Result memory predicted = lens.stress(manager, l, _shock(-4_000));

        ex.setMark(BTC, (BTC_PRICE * 60) / 100);
        vm.startPrank(keeper);
        a.freeze();
        a.unwind(BTC, type(uint256).max); // underwater: the venue absorbs what the margin cannot
        a.settleFrozen();
        vm.stopPrank();

        assertEq(pool.totalLosses(), predicted.totalLoss, "lens prediction != realized loss");
        assertEq(pool.juniorAssets(), predicted.juniorAfter);
    }

    function test_noShockNoLoss() public {
        (CreditLine a, CreditLine b) = _openAB();
        RiskLens.Result memory r = lens.stress(manager, _lines(a, b), new RiskLens.Shock[](0));
        assertEq(r.totalLoss, 0);
        assertEq(r.lines[0].equityAfter, r.lines[0].equityNow);
        assertEq(r.lines[1].equityAfter, r.lines[1].equityNow);
    }

    function test_rejectsAddressesThatAreNotLines() public {
        address[] memory l = new address[](1);
        l[0] = alice;
        vm.expectRevert(abi.encodeWithSelector(RiskLens.NotALine.selector, alice));
        lens.stress(manager, l, _shock(-1_000));
    }
}
