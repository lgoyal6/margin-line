// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IExchange} from "perpl-interfaces/IExchange.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {CircuitBreaker, IAggregatorV3} from "../../src/CircuitBreaker.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";

contract MockFeed is IAggregatorV3 {
    int256 public answer = 1e8;
    uint256 public updatedAt;

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract EnforcementTest is Fixture {
    uint256 constant DEPOSIT = 1_000e6;
    uint256 constant PRINCIPAL = 2_000e6;

    function _unhealthyLine() internal returns (CreditLine line) {
        line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 6_000, 300);
        ex.setMark(BTC, (BTC_PRICE * 8_500) / 10_000); // health about 1.05
    }

    // ------------------------------------------------------------ bounty

    function test_freezerEarnsCappedBountyAtSettlement() public {
        CreditLine line = _unhealthyLine();
        vm.startPrank(keeper);
        line.freeze();
        assertEq(line.enforcer(), keeper);
        assertEq(line.bountyOwed(), 10e6, "0.5% of $2,000");
        line.unwind(BTC, type(uint256).max);
        line.settleFrozen();
        vm.stopPrank();
        assertEq(ausd.balanceOf(keeper), 10e6);
        assertEq(pool.totalLosses(), 0, "lender still whole after the bounty");
    }

    function test_bountyCap() public {
        vm.prank(admin);
        manager.setFreezeBounty(200, 5e6); // 2% but at most $5
        CreditLine line = _unhealthyLine();
        vm.prank(keeper);
        line.freeze();
        assertEq(line.bountyOwed(), 5e6);
    }

    function test_borrowerAndSessionKeysEarnNoBounty() public {
        CreditLine line = _unhealthyLine();
        vm.prank(alice);
        line.freeze();
        assertEq(line.bountyOwed(), 0);
        assertEq(line.enforcer(), address(0));
    }

    function test_sessionKeyEarnsNoBounty() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        address session = makeAddr("session");
        uint40 expiry = uint40(block.timestamp + 1 days);
        IdentityRegistry.Proof memory p =
            _lineProof(line, keccak256(abi.encode("grantSession", session, expiry, uint96(10_000e6), uint96(10_000e6))));
        vm.prank(alice);
        line.grantSession(session, expiry, 10_000e6, 10_000e6, p);
        _long(line, 6_000, 300);
        ex.setMark(BTC, (BTC_PRICE * 8_500) / 10_000);
        vm.prank(session);
        line.freeze();
        assertEq(line.bountyOwed(), 0);
    }

    function test_bountyTooHighRejected() public {
        vm.prank(admin);
        vm.expectRevert(CreditManager.InvalidParams.selector);
        manager.setFreezeBounty(201, 1e6);
    }

    // ------------------------------------------------------------ breaker: what it blocks

    function test_pauseBlocksNewLinesNewPositionsAndSweeps() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        vm.prank(admin);
        breaker.pause();

        IExchange.OrderDesc[] memory o = _order(0, (BTC_PRICE * 10_040) / 10_000, 100, 200);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.NewRiskBlocked.selector, CircuitBreaker.Reason.Paused));
        line.trade(o);

        IdentityRegistry.Proof memory p = _lineProof(line, keccak256(abi.encode("sweep", uint256(100e6))));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.NewRiskBlocked.selector, CircuitBreaker.Reason.Paused));
        line.sweep(100e6, p);

        _registerPasskey(makeAddr("bob"));
        _approve(makeAddr("bob"), 1_000e6);
        ausd.mint(makeAddr("bob"), 500e6);
        vm.startPrank(makeAddr("bob"));
        ausd.approve(address(manager), 500e6);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.NewRiskBlocked.selector, CircuitBreaker.Reason.Paused));
        manager.openLine(500e6, 1_000e6);
        vm.stopPrank();
    }

    /// @notice The breaker can never trap anyone: everything that reduces risk still works.
    function test_pauseNeverBlocksClosingRepayingFreezingUnwindingOrSettling() public {
        CreditLine healthy = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(healthy, 1_000, 200);
        CreditLine sick = _openLine(makeAddr("carol"), DEPOSIT, PRINCIPAL);
        _long(sick, 6_000, 300);
        vm.prank(admin);
        breaker.pause();

        _closeLong(healthy, 1_000); // closing a position
        ausd.mint(alice, 100e6);
        vm.startPrank(alice);
        ausd.approve(address(healthy), 100e6);
        healthy.repay(100e6); // repaying
        vm.stopPrank();
        _close(healthy); // closing the line

        ex.setMark(BTC, (BTC_PRICE * 8_500) / 10_000);
        vm.startPrank(keeper);
        sick.freeze(); // freezing
        sick.unwind(BTC, type(uint256).max); // unwinding
        sick.settleFrozen(); // settling
        vm.stopPrank();
        assertEq(uint8(sick.state()), uint8(CreditLine.State.Closed));
    }

    function test_onlyOwnerOrPauserPausesAndOnlyOwnerResumes() public {
        address guardianAddr = makeAddr("guardian");
        vm.prank(admin);
        breaker.setPauser(guardianAddr);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(CircuitBreaker.NotPauser.selector);
        breaker.pause();
        vm.prank(guardianAddr);
        breaker.pause();
        vm.prank(guardianAddr);
        vm.expectRevert();
        breaker.unpause();
        vm.prank(admin);
        breaker.unpause();
        assertFalse(breaker.paused());
    }

    // ------------------------------------------------------------ breaker: triggers

    function test_venuePausedBlocksOpensButNotCloses() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        _long(line, 1_000, 200);
        ex.setPaused(BTC, true);
        IExchange.OrderDesc[] memory o = _order(0, (BTC_PRICE * 10_040) / 10_000, 100, 200);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.NewRiskBlocked.selector, CircuitBreaker.Reason.VenuePaused));
        line.trade(o);
        _closeLong(line, 1_000);
    }

    function test_thinInsuranceBlocksOpens() public {
        CreditLine line = _openLine(alice, DEPOSIT, PRINCIPAL);
        vm.prank(admin);
        breaker.setMinInsuranceBps(100); // insurance must be at least 1% of one side's OI notional
        ex.setInsurance(BTC, 5_000e6, 1_000_000); // $5,000 against 10 BTC ($1M) of OI: 0.5%
        IExchange.OrderDesc[] memory o = _order(0, (BTC_PRICE * 10_040) / 10_000, 100, 200);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditLine.NewRiskBlocked.selector, CircuitBreaker.Reason.InsuranceThin));
        line.trade(o);

        ex.setInsurance(BTC, 20_000e6, 1_000_000); // 2%
        _long(line, 100, 200);
    }

    function test_depegAndStaleFeedBlockNewRisk() public {
        MockFeed feed = new MockFeed();
        feed.set(1e8, block.timestamp);
        vm.prank(admin);
        breaker.setPegConfig(feed, 99_500_000, 1 hours);
        assertEq(uint8(breaker.globalStatus()), uint8(CircuitBreaker.Reason.None));

        feed.set(99_000_000, block.timestamp); // AUSD at $0.99
        assertEq(uint8(breaker.globalStatus()), uint8(CircuitBreaker.Reason.Depeg));

        feed.set(1e8, block.timestamp);
        vm.warp(block.timestamp + 2 hours);
        assertEq(uint8(breaker.globalStatus()), uint8(CircuitBreaker.Reason.PegStale));
    }
}
