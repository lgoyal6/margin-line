// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";
import {CreditPool} from "./CreditPool.sol";
import {TrancheVault} from "./TrancheVault.sol";
import {CreditManager} from "./CreditManager.sol";
import {CreditLine} from "./CreditLine.sol";
import {TradeGuard} from "./TradeGuard.sol";
import {CircuitBreaker} from "./CircuitBreaker.sol";
import {RiskCurator} from "./RiskCurator.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {HistoryLinkRegistry} from "./HistoryLinkRegistry.sol";
import {ScoreOracle, IGuardianSource} from "./ScoreOracle.sol";

/// @title MarketFactory
/// @notice Deploys a complete, isolated credit market for one curator: its own pool and tranche
///         vaults, guard, manager, line implementation, breaker and RiskCurator, wired together and
///         handed to the curator in a single transaction. A loss in one market cannot touch another.
///
///         Because this factory wrote every component, a market it lists is known to be the real
///         code, wired correctly, governed by a RiskCurator with at least `MIN_TIMELOCK`. Apps should
///         show lenders only markets from `isMarket`.
/// @dev The factory carries the creation code of every component (about 80 KB), which fits only
///      because Monad allows contracts up to 128 KB.
contract MarketFactory {
    struct MarketConfig {
        address curatorOwner;
        address guardian;
        address underwriter;
        uint256 timelock;
        uint256 perpId; // first allowed Perpl market
        uint16 maxLeverageHdths;
        uint16 bandBps;
        uint256 exposureCap;
        string name; // e.g. "Margin Line BTC" -> "Margin Line BTC Senior"
        string symbol; // e.g. "mlBTC" -> "mlBTC-SR"
        address scorePublisher; // posts score epochs to the market's ScoreOracle
        uint256 publisherBond; // native MON the publisher stakes per epoch
        uint256 challengeBond; // native MON a disputer stakes
    }

    struct Market {
        CreditPool pool;
        TrancheVault senior;
        TrancheVault junior;
        CreditManager manager;
        TradeGuard guard;
        CircuitBreaker breaker;
        RiskCurator curator;
        CreditLine lineImplementation;
        ScoreOracle scoreOracle;
    }

    uint256 public constant MAX_MARK_AGE_SEC = 600;

    IERC20 public immutable asset;
    IExchange public immutable exchange;
    DelegatedAccountFactory public immutable accountFactory;
    IdentityRegistry public immutable identity;
    HistoryLinkRegistry public immutable historyLinks;

    Market[] internal _markets;
    mapping(address pool => bool) public isMarket;

    event MarketCreated(uint256 indexed index, address indexed pool, address indexed curator, string name);

    constructor(IERC20 asset_, IExchange exchange_, DelegatedAccountFactory accountFactory_, IdentityRegistry identity_) {
        asset = asset_;
        exchange = exchange_;
        accountFactory = accountFactory_;
        identity = identity_;
        historyLinks = new HistoryLinkRegistry(exchange_);
    }

    function marketsLength() external view returns (uint256) {
        return _markets.length;
    }

    function markets(uint256 i) external view returns (Market memory) {
        return _markets[i];
    }

    function createMarket(MarketConfig calldata c) external returns (Market memory m) {
        m.breaker = new CircuitBreaker(address(this));
        m.pool = new CreditPool(asset, address(this));
        m.senior = new TrancheVault(m.pool, CreditPool.Tranche.Senior, string.concat(c.name, " Senior"), string.concat(c.symbol, "-SR"));
        m.junior = new TrancheVault(m.pool, CreditPool.Tranche.Junior, string.concat(c.name, " Junior"), string.concat(c.symbol, "-JR"));
        m.guard = new TradeGuard(address(this), MAX_MARK_AGE_SEC);
        m.manager = new CreditManager(m.pool, exchange, identity, address(this));
        m.lineImplementation = new CreditLine(address(m.manager), m.pool, m.guard, exchange, accountFactory, asset, identity);
        // The curator's constructor validates the timelock bounds.
        m.curator = new RiskCurator(m.pool, m.manager, m.guard, m.breaker, c.curatorOwner, c.guardian, c.timelock);
        m.scoreOracle = new ScoreOracle(
            address(m.curator), IGuardianSource(address(m.curator)), c.scorePublisher, c.publisherBond, c.challengeBond
        );
        m.curator.wireScoreOracle(address(m.scoreOracle));
        m.manager.setHistoryLinks(historyLinks);
        m.manager.setScoreOracle(m.scoreOracle);

        m.pool.wire(address(m.manager), address(m.senior), address(m.junior));
        m.manager.setLineImplementation(address(m.lineImplementation));
        m.manager.setBreaker(m.breaker);
        m.manager.setUnderwriter(c.underwriter);
        m.breaker.setPauser(c.guardian);
        m.guard.setMarket(c.perpId, true, c.maxLeverageHdths, c.bandBps);
        if (c.exposureCap != 0) m.guard.setExposureCap(c.perpId, c.exposureCap);

        _handOver(m.pool, m.curator);
        _handOver(m.manager, m.curator);
        _handOver(m.guard, m.curator);
        _handOver(m.breaker, m.curator);

        isMarket[address(m.pool)] = true;
        _markets.push(m);
        emit MarketCreated(_markets.length - 1, address(m.pool), address(m.curator), c.name);
    }

    function _handOver(Ownable2Step component, RiskCurator curator) internal {
        component.transferOwnership(address(curator));
        curator.acceptOwnershipOf(component);
    }
}
