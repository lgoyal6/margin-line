// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../utils/Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {RiskCurator} from "../../src/RiskCurator.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {CreditLine, ICreditManager} from "../../src/CreditLine.sol";
import {TradeGuard} from "../../src/TradeGuard.sol";
import {CircuitBreaker} from "../../src/CircuitBreaker.sol";
import {ScoreOracle} from "../../src/ScoreOracle.sol";

/// @notice Curator markets: deployed whole by the factory, tightened instantly, loosened only
///         through a timelock the guardian can veto.
contract CuratorTest is Fixture {
    MarketFactory internal mf;
    MarketFactory.Market internal m;
    address internal curatorOwner = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal mUnderwriter = makeAddr("market-underwriter");
    address internal publisher = makeAddr("score-publisher");
    uint256 internal constant TIMELOCK = 3 days;

    function setUp() public override {
        super.setUp();
        mf = new MarketFactory(IERC20(address(ausd)), IExchange(address(ex)), factory, identity);
        uint256 g = gasleft();
        m = mf.createMarket(
            MarketFactory.MarketConfig({
                curatorOwner: curatorOwner,
                guardian: guardian,
                underwriter: mUnderwriter,
                timelock: TIMELOCK,
                perpId: BTC,
                maxLeverageHdths: 300,
                bandBps: 50,
                exposureCap: 50_000e6,
                name: "Margin Line BTC",
                symbol: "mlBTC",
                scorePublisher: publisher,
                publisherBond: 1 ether,
                challengeBond: 0.5 ether
            })
        );
        emit log_named_uint("createMarket gas", g - gasleft());
    }

    // ------------------------------------------------------------ factory

    function test_factoryHandsEveryComponentToTheCurator() public view {
        assertEq(m.pool.owner(), address(m.curator));
        assertEq(m.manager.owner(), address(m.curator));
        assertEq(m.guard.owner(), address(m.curator));
        assertEq(m.breaker.owner(), address(m.curator));
        assertEq(m.curator.owner(), curatorOwner);
        assertEq(m.curator.guardian(), guardian);
        assertEq(m.breaker.pauser(), guardian);
        assertTrue(mf.isMarket(address(m.pool)));
        assertEq(mf.marketsLength(), 1);
        assertEq(m.pool.manager(), address(m.manager));
        assertEq(m.pool.seniorVault(), address(m.senior));
        assertEq(m.pool.juniorVault(), address(m.junior));
        assertEq(m.manager.lineImplementation(), address(m.lineImplementation));
        assertEq(m.manager.underwriter(), mUnderwriter);
        assertEq(m.guard.exposureCap(BTC), 50_000e6);
        assertEq(m.senior.symbol(), "mlBTC-SR");
        assertEq(m.junior.name(), "Margin Line BTC Junior");
    }

    function test_factoryMarketLendsAndTradesEndToEnd() public {
        _lendTo(m.junior, lender, 100_000e6);
        _registerPasskey(alice);
        vm.prank(mUnderwriter);
        m.manager.approve(alice, 2_000e6, 1_000, uint40(block.timestamp + 1 days));
        ausd.mint(alice, 1_000e6);
        vm.startPrank(alice);
        ausd.approve(address(m.manager), 1_000e6);
        CreditLine line = CreditLine(m.manager.openLine(1_000e6, 2_000e6));
        vm.stopPrank();
        assertEq(m.pool.principalOf(address(line)), 2_000e6);
        _long(line, 2_000, 200);
        assertEq(line.account().owner(), address(line));
    }

    function test_marketsAreIsolated() public {
        // A loss in the factory market leaves the fixture's pool untouched, and vice versa.
        _lendTo(m.junior, lender, 100_000e6);
        uint256 fixtureJunior = pool.juniorAssets();
        _registerPasskey(alice);
        vm.prank(mUnderwriter);
        m.manager.approve(alice, 2_000e6, 1_000, uint40(block.timestamp + 1 days));
        ausd.mint(alice, 1_000e6);
        vm.startPrank(alice);
        ausd.approve(address(m.manager), 1_000e6);
        CreditLine line = CreditLine(m.manager.openLine(1_000e6, 2_000e6));
        vm.stopPrank();
        vm.prank(address(line));
        m.pool.settle(0, 0, 2_000e6);
        assertEq(m.pool.juniorAssets(), 98_000e6);
        assertEq(pool.juniorAssets(), fixtureJunior);
        // A line of one market is not a line of another.
        vm.prank(address(line));
        vm.expectRevert(CreditPool.OnlyLine.selector);
        pool.settle(0, 0, 1);
    }

    function test_rejectsTimelockOutsideBounds() public {
        MarketFactory.MarketConfig memory c = _config();
        c.timelock = 1 days - 1;
        vm.expectRevert(RiskCurator.InvalidTimelock.selector);
        mf.createMarket(c);
        c.timelock = 30 days + 1;
        vm.expectRevert(RiskCurator.InvalidTimelock.selector);
        mf.createMarket(c);
    }

    // ------------------------------------------------------------ tightening is instant

    function test_tighteningIsInstant() public {
        vm.startPrank(curatorOwner);
        m.curator.tightenMaxLine(1_000);
        m.curator.tightenExposureCap(BTC, 10_000e6);
        m.curator.tightenMarket(BTC, true, 200, 30);
        m.curator.tightenPool(2_000, 3_000, 8_000);
        m.curator.tightenInsuranceFloor(25);
        m.curator.tightenRisk(ICreditManager.RiskParams(11_500, 14_000, 13_000), 20_000);
        m.curator.revokeUnderwriter();
        vm.stopPrank();

        assertEq(m.manager.maxLineBps(), 1_000);
        assertEq(m.guard.exposureCap(BTC), 10_000e6);
        (, uint16 lev, uint16 band) = m.guard.markets(BTC);
        assertEq(lev, 200);
        assertEq(band, 30);
        assertEq(m.pool.reserveBps(), 2_000);
        assertEq(m.pool.minJuniorBps(), 3_000);
        assertEq(m.pool.maxUtilizationBps(), 8_000);
        assertEq(m.breaker.minInsuranceBps(), 25);
        assertEq(m.manager.maxLeverageOnDepositBps(), 20_000);
        assertEq(m.manager.underwriter(), address(0));
    }

    function test_looseningCannotUseTheInstantPath() public {
        vm.startPrank(curatorOwner);
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenMaxLine(5_000);
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenExposureCap(BTC, 50_000e6 + 1);
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenExposureCap(BTC, 0); // zero means uncapped
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenMarket(BTC, true, 400, 50);
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenMarket(BTC, true, 300, 60);
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenMarket(2, true, 100, 10); // allowing a new market adds risk
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenPool(1_000, 2_000, 9_500);
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenPool(500, 2_000, 9_000);
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenRisk(ICreditManager.RiskParams(10_500, 13_000, 12_500), 30_000);
        vm.expectRevert(RiskCurator.NotTightening.selector);
        m.curator.tightenRisk(ICreditManager.RiskParams(11_000, 13_000, 12_500), 40_000);
        vm.stopPrank();
    }

    function test_onlyCuratorTightens() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        m.curator.tightenMaxLine(1_000);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        m.curator.tightenMaxLine(1_000);
    }

    function test_componentsRejectDirectAdminCalls() public {
        vm.prank(curatorOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, curatorOwner));
        m.manager.setMaxLineBps(10_000);
    }

    // ------------------------------------------------------------ loosening is timelocked

    function test_looseningWaitsOutTheTimelock() public {
        bytes memory data = abi.encodeCall(CreditManager.setMaxLineBps, (5_000));
        vm.prank(curatorOwner);
        bytes32 id = m.curator.submit(address(m.manager), data);
        assertEq(m.curator.pending(id), block.timestamp + TIMELOCK);

        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.expectRevert(abi.encodeWithSelector(RiskCurator.Timelocked.selector, id, block.timestamp + 1));
        m.curator.execute(address(m.manager), data);

        vm.warp(block.timestamp + 1);
        vm.prank(alice); // anyone can execute a matured change
        m.curator.execute(address(m.manager), data);
        assertEq(m.manager.maxLineBps(), 5_000);
        assertEq(m.curator.pending(id), 0);

        vm.expectRevert(abi.encodeWithSelector(RiskCurator.NotPending.selector, id));
        m.curator.execute(address(m.manager), data); // not replayable
    }

    function test_guardianVetoesAPendingChange() public {
        bytes memory data = abi.encodeCall(TradeGuard.setMarket, (BTC, true, 1_000, 500));
        vm.prank(curatorOwner);
        bytes32 id = m.curator.submit(address(m.guard), data);
        vm.prank(alice);
        vm.expectRevert(RiskCurator.OnlyGuardianOrOwner.selector);
        m.curator.revoke(id);
        vm.prank(guardian);
        m.curator.revoke(id);
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(RiskCurator.NotPending.selector, id));
        m.curator.execute(address(m.guard), data);
    }

    function test_ownershipTransferIsTimelocked() public {
        bytes memory data = abi.encodeCall(Ownable.transferOwnership, (curatorOwner));
        vm.prank(curatorOwner);
        m.curator.submit(address(m.pool), data);
        vm.expectRevert();
        m.curator.execute(address(m.pool), data);
        vm.warp(block.timestamp + TIMELOCK);
        m.curator.execute(address(m.pool), data);
        assertEq(m.pool.pendingOwner(), curatorOwner);
    }

    function test_cannotTargetUnknownContracts() public {
        vm.prank(curatorOwner);
        vm.expectRevert(abi.encodeWithSelector(RiskCurator.UnknownTarget.selector, address(pool)));
        m.curator.submit(address(pool), abi.encodeCall(CreditPool.setParams, (0, 0, 0, 10_000)));
    }

    // ------------------------------------------------------------ guardian, pause, timelock

    function test_guardianPausesInstantlyButUnpauseIsTimelocked() public {
        vm.prank(guardian);
        m.curator.pause();
        assertEq(uint8(m.breaker.globalStatus()), uint8(CircuitBreaker.Reason.Paused));

        bytes memory data = abi.encodeCall(CircuitBreaker.unpause, ());
        vm.prank(curatorOwner);
        m.curator.submit(address(m.breaker), data);
        vm.warp(block.timestamp + TIMELOCK);
        m.curator.execute(address(m.breaker), data);
        assertEq(uint8(m.breaker.globalStatus()), uint8(CircuitBreaker.Reason.None));
    }

    function test_guardianAndTimelockChangesGoThroughTheTimelock() public {
        address newGuardian = makeAddr("new-guardian");
        vm.prank(curatorOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, curatorOwner));
        m.curator.setGuardian(newGuardian);

        bytes memory g = abi.encodeCall(RiskCurator.setGuardian, (newGuardian));
        bytes memory t = abi.encodeCall(RiskCurator.setTimelock, (1 days));
        vm.startPrank(curatorOwner);
        m.curator.submit(address(m.curator), g);
        m.curator.submit(address(m.curator), t);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK);
        m.curator.execute(address(m.curator), g);
        m.curator.execute(address(m.curator), t);
        assertEq(m.curator.guardian(), newGuardian);
        assertEq(m.breaker.pauser(), newGuardian);
        assertEq(m.curator.timelock(), 1 days);
    }

    function test_lengtheningTimelockIsInstant() public {
        vm.startPrank(curatorOwner);
        m.curator.increaseTimelock(7 days);
        assertEq(m.curator.timelock(), 7 days);
        vm.expectRevert(RiskCurator.InvalidTimelock.selector);
        m.curator.increaseTimelock(5 days);
        vm.stopPrank();
    }

    /// A pending loosening is visible for the whole timelock: a junior lender who disagrees can
    /// withdraw before it takes effect.
    function test_lendersCanExitBeforeALooseningLands() public {
        _lendTo(m.junior, lender, 100_000e6);
        bytes memory data = abi.encodeCall(CreditManager.setMaxLineBps, (10_000));
        vm.prank(curatorOwner);
        m.curator.submit(address(m.manager), data);
        uint256 shares = m.junior.balanceOf(lender);
        vm.prank(lender);
        m.junior.redeem(shares, lender, lender);
        vm.warp(block.timestamp + TIMELOCK);
        m.curator.execute(address(m.manager), data);
        assertApproxEqAbs(ausd.balanceOf(lender), 100_000e6, 1);
    }

    // ------------------------------------------------------------ score oracle

    /// Regression: the oracle was owned by the curator but unreachable through it, and disputes could
    /// only be resolved by the owner, so one dispute froze an epoch for good.
    function test_factoryOracleIsGovernedAndGuardianResolvesInstantly() public {
        ScoreOracle o = m.scoreOracle;
        assertEq(o.owner(), address(m.curator));
        assertEq(o.publisher(), publisher);
        assertEq(o.guardian(), guardian);
        assertEq(m.curator.scoreOracle(), address(o));

        vm.deal(publisher, 5 ether);
        vm.roll(block.number + 2);
        vm.prank(publisher);
        o.propose{value: 1 ether}(1, bytes32(uint256(1)), block.number - 1, "epoch");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 id = o.openArbitratedChallenge{value: 0.5 ether}(1);
        vm.prank(guardian);
        o.resolveArbitrated(id, true); // no timelock in the way
        vm.warp(block.timestamp + 1 days);
        o.finalize(1);
        assertTrue(o.isFinalized(1));

        // Settings change through the curator's public timelock, like any other loosening.
        bytes memory data = abi.encodeCall(ScoreOracle.setChallengeWindow, (1 hours));
        vm.prank(curatorOwner);
        m.curator.submit(address(o), data);
        vm.warp(block.timestamp + TIMELOCK);
        m.curator.execute(address(o), data);
        assertEq(o.challengeWindow(), 1 hours);
    }

    function test_onlyFactoryWiresTheOracleOnce() public {
        vm.prank(curatorOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, curatorOwner));
        m.curator.wireScoreOracle(alice);
        vm.prank(address(mf));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(mf)));
        m.curator.wireScoreOracle(alice);
    }

    function _config() internal view returns (MarketFactory.MarketConfig memory) {
        return MarketFactory.MarketConfig({
            curatorOwner: curatorOwner,
            guardian: guardian,
            underwriter: mUnderwriter,
            timelock: TIMELOCK,
            perpId: BTC,
            maxLeverageHdths: 300,
            bandBps: 50,
            exposureCap: 0,
            name: "X",
            symbol: "X",
            scorePublisher: publisher,
            publisherBond: 1 ether,
            challengeBond: 0.5 ether
        });
    }
}
