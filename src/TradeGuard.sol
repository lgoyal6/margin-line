// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";

/// @title TradeGuard
/// @notice The rulebook every borrower order must pass before CreditLine forwards it to Perpl.
///         It plays the role of Gearbox's adapter allowlist: borrowed collateral can only be used for
///         the actions listed here, priced within a band around Perpl's own mark price.
/// @dev Why each rule exists:
///      - Market allowlist: lines are valued by iterating these markets, so a position elsewhere
///        would be invisible to the health check.
///      - Open/close order types only: no Change/Cancel/collateral ops through the trade path.
///      - Immediate-or-cancel, never post-only: nothing rests on the book, so no collateral is locked
///        and no stale order can fill after a freeze.
///      - Price band around the mark: the main anti-drain rule. A borrower colluding with another
///        wallet could otherwise buy far above or sell far below fair value and move margin out.
///      - Leverage cap on opens: bounds how fast a line can lose its margin.
///      - amountCNS must be zero: orders cannot move collateral.
contract TradeGuard is Ownable2Step {
    struct Market {
        bool allowed;
        uint16 maxLeverageHdths; // e.g. 300 = 3.00x
        uint16 bandBps; // max distance of a limit price from the mark, e.g. 50 = 0.50%
    }

    uint8 internal constant OPEN_LONG = 0;
    uint8 internal constant OPEN_SHORT = 1;
    uint8 internal constant CLOSE_LONG = 2;
    uint8 internal constant CLOSE_SHORT = 3;

    /// @notice Hard ceilings governance cannot exceed.
    uint16 public constant MAX_BAND_BPS = 500;
    uint16 public constant MAX_LEVERAGE_HDTHS = 1_000;
    uint256 public constant MAX_MARKETS = 8;

    /// @notice Orders are rejected if Perpl's mark is older than this.
    uint256 public maxMarkAgeSec;

    mapping(uint256 perpId => Market) public markets;
    /// @notice Largest position one line may hold in a market, in AUSD notional at the mark.
    ///         Zero means no cap beyond leverage and health.
    mapping(uint256 perpId => uint256) public exposureCap;
    uint256[] internal _marketIds;

    error MarketNotAllowed(uint256 perpId);
    error OrderTypeNotAllowed(uint8 orderType);
    error MustBeImmediateOrCancel();
    error CollateralMoveNotAllowed();
    error LeverageTooHigh(uint256 leverageHdths, uint256 max);
    error PriceOutsideBand(uint256 pricePNS, uint256 markPNS, uint16 bandBps);
    error StaleMark(uint256 markTimestamp);
    error InvalidConfig();
    error TooManyMarkets();
    error ExposureTooLarge(uint256 perpId, uint256 notional, uint256 cap);

    event MarketSet(uint256 indexed perpId, bool allowed, uint16 maxLeverageHdths, uint16 bandBps);
    event MaxMarkAgeSet(uint256 maxMarkAgeSec);
    event ExposureCapSet(uint256 indexed perpId, uint256 cap);

    constructor(address owner_, uint256 maxMarkAgeSec_) Ownable(owner_) {
        maxMarkAgeSec = maxMarkAgeSec_;
    }

    /// @notice Allow or update a market. Disallowing only blocks new orders: the band is kept so
    ///         frozen lines can still be unwound in that market.
    function setMarket(uint256 perpId, bool allowed, uint16 maxLeverageHdths, uint16 bandBps) external onlyOwner {
        Market storage m = markets[perpId];
        if (!allowed) {
            m.allowed = false;
            emit MarketSet(perpId, false, m.maxLeverageHdths, m.bandBps);
            return;
        }
        if (bandBps == 0 || bandBps > MAX_BAND_BPS || maxLeverageHdths < 100 || maxLeverageHdths > MAX_LEVERAGE_HDTHS) {
            revert InvalidConfig();
        }
        if (m.bandBps == 0) {
            if (_marketIds.length >= MAX_MARKETS) revert TooManyMarkets();
            _marketIds.push(perpId);
        }
        markets[perpId] = Market(true, maxLeverageHdths, bandBps);
        emit MarketSet(perpId, true, maxLeverageHdths, bandBps);
    }

    function setExposureCap(uint256 perpId, uint256 cap) external onlyOwner {
        exposureCap[perpId] = cap;
        emit ExposureCapSet(perpId, cap);
    }

    function setMaxMarkAge(uint256 maxMarkAgeSec_) external onlyOwner {
        if (maxMarkAgeSec_ == 0) revert InvalidConfig();
        maxMarkAgeSec = maxMarkAgeSec_;
        emit MaxMarkAgeSet(maxMarkAgeSec_);
    }

    /// @notice Every market that has ever been allowed. CreditLine values positions in all of them,
    ///         including ones later disallowed, so nothing becomes invisible to the health check.
    function marketIds() external view returns (uint256[] memory) {
        return _marketIds;
    }

    /// @notice Reverts if any order breaks a rule.
    /// @return increasesRisk True if any order can open or grow a position.
    function checkOrders(IExchange exchange, IExchange.OrderDesc[] calldata orders)
        external
        view
        returns (bool increasesRisk)
    {
        for (uint256 i; i < orders.length; ++i) {
            if (_check(exchange, orders[i])) increasesRisk = true;
        }
    }

    /// @notice The price a keeper uses to unwind a frozen line: the edge of the band, on the side
    ///         that closes the position.
    function closePrice(IExchange exchange, uint256 perpId, bool isLong) external view returns (uint256) {
        (uint256 mark, uint16 bandBps) = _markAndBand(exchange, perpId);
        return isLong ? (mark * (10_000 - bandBps) + 9_999) / 10_000 : (mark * (10_000 + bandBps)) / 10_000;
    }

    /// @notice AUSD value (collateral units) of an order at its limit price, using Perpl's own
    ///         price, lot and collateral decimals. Used to meter session keys.
    function orderNotional(IExchange exchange, IExchange.OrderDesc calldata o) public view returns (uint256) {
        IExchange.PerpetualInfoV2 memory p = exchange.getPerpetualInfoV2(o.perpId);
        (,,, uint256 collateralDecimals,,) = exchange.getExchangeInfo();
        return (o.pricePNS * o.lotLNS * 10 ** collateralDecimals) / 10 ** (p.priceDecimals + p.lotDecimals);
    }

    /// @notice Reverts with StaleMark if Perpl's mark for `perpId` is older than `maxMarkAgeSec`.
    function requireFreshMark(IExchange exchange, uint256 perpId) external view {
        _markAndBand(exchange, perpId);
    }

    /// @notice Reverts if a position of `lotLNS` in `perpId` is worth more than the market's cap at
    ///         the current mark. CreditLine calls this after every trade that adds risk.
    function checkExposure(IExchange exchange, uint256 perpId, uint256 lotLNS) external view {
        uint256 cap = exposureCap[perpId];
        if (cap == 0 || lotLNS == 0) return;
        IExchange.PerpetualInfoV2 memory p = exchange.getPerpetualInfoV2(perpId);
        (,,, uint256 collateralDecimals,,) = exchange.getExchangeInfo();
        uint256 notional = (p.markPNS * lotLNS * 10 ** collateralDecimals) / 10 ** (p.priceDecimals + p.lotDecimals);
        if (notional > cap) revert ExposureTooLarge(perpId, notional, cap);
    }

    function _check(IExchange exchange, IExchange.OrderDesc calldata o) internal view returns (bool opens) {
        Market memory m = markets[o.perpId];
        if (!m.allowed) revert MarketNotAllowed(o.perpId);

        uint8 t = IExchange.OrderDescEnum.unwrap(o.orderType);
        if (t > CLOSE_SHORT) revert OrderTypeNotAllowed(t);
        if (!o.immediateOrCancel || o.postOnly) revert MustBeImmediateOrCancel();
        if (o.amountCNS != 0) revert CollateralMoveNotAllowed();

        opens = t == OPEN_LONG || t == OPEN_SHORT;
        if (opens && o.leverageHdths > m.maxLeverageHdths) revert LeverageTooHigh(o.leverageHdths, m.maxLeverageHdths);

        (uint256 mark,) = _markAndBand(exchange, o.perpId);
        bool buys = t == OPEN_LONG || t == CLOSE_SHORT;
        if (buys) {
            if (o.pricePNS * 10_000 > mark * (10_000 + m.bandBps)) revert PriceOutsideBand(o.pricePNS, mark, m.bandBps);
        } else {
            if (o.pricePNS * 10_000 < mark * (10_000 - m.bandBps)) revert PriceOutsideBand(o.pricePNS, mark, m.bandBps);
        }
    }

    function _markAndBand(IExchange exchange, uint256 perpId) internal view returns (uint256 mark, uint16 bandBps) {
        IExchange.PerpetualInfoV2 memory p = exchange.getPerpetualInfoV2(perpId);
        if (block.timestamp > p.markTimestamp + maxMarkAgeSec) revert StaleMark(p.markTimestamp);
        bandBps = markets[perpId].bandBps; // nonzero for any market that was ever allowed
        if (bandBps == 0) revert MarketNotAllowed(perpId);
        mark = p.markPNS;
    }
}
