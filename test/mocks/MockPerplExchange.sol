// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";

/// @notice Minimal stand-in for Perpl's Exchange, used only for fast unit and invariant tests.
///         Integration against the real exchange lives in test/fork. Models what CreditLine relies
///         on: accounts with a free balance, isolated-margin positions marked to a settable mark,
///         IOC fills at mark plus or minus a spread, a taker fee, and liquidation that returns 80% of
///         residual margin and floors bankrupt positions at zero.
/// @dev Units chosen so that notional CNS = pricePNS * lotLNS (price 1 decimal, lot 5 decimals,
///      collateral 6 decimals), which keeps the arithmetic readable.
contract MockPerplExchange {
    using SafeERC20 for IERC20;

    struct Position {
        uint8 side; // 0 long, 1 short
        uint256 lot;
        uint256 entry;
        uint256 deposit;
    }

    IERC20 public immutable token;
    uint256 public nextAccountId = 1;
    uint256 public spreadBps = 5;
    uint256 public takerFeeBps = 4;
    uint256 public minAccountOpen = 10e6;
    uint256 public badDebt; // shortfall absorbed by the venue (insurance fund and ADL in reality)

    mapping(uint256 id => address) public accountAddr;
    mapping(address => uint256) public accountIdOf;
    mapping(uint256 id => uint256) public balance;
    mapping(uint256 perpId => uint256) public mark;
    mapping(uint256 perpId => uint256) public markTs;
    mapping(uint256 perpId => bool) public paused; // Perpl reports status 0 when a market is paused
    mapping(uint256 perpId => uint256) public insurance;
    mapping(uint256 perpId => bool) public markInvalid; // Perpl's getPositionV2 reports whether its mark is usable
    mapping(uint256 perpId => uint256) public openInterest;
    mapping(uint256 perpId => mapping(uint256 id => Position)) internal _pos;

    error NoAccount();
    error NotFilled();
    error Insufficient();
    error Unsupported();

    constructor(IERC20 token_) {
        token = token_;
    }

    // ------------------------------------------------------------ test controls

    function setMark(uint256 perpId, uint256 markPNS) external {
        mark[perpId] = markPNS;
        markTs[perpId] = block.timestamp;
    }

    function setPaused(uint256 perpId, bool p) external {
        paused[perpId] = p;
    }

    function setInsurance(uint256 perpId, uint256 insuranceCNS, uint256 oiLNS) external {
        insurance[perpId] = insuranceCNS;
        openInterest[perpId] = oiLNS;
    }

    /// @notice Venue liquidation: closes at mark, returns 80% of positive residual margin.
    function liquidate(uint256 perpId, uint256 id) external {
        Position storage p = _pos[perpId][id];
        if (p.lot == 0) return;
        int256 value = int256(p.deposit) + _pnl(p, mark[perpId]);
        if (value > 0) balance[id] += (uint256(value) * 80) / 100;
        else badDebt += uint256(-value);
        delete _pos[perpId][id];
    }

    // ------------------------------------------------------------ IExchange subset

    function getExchangeInfo() external view returns (uint256, uint256, uint256, uint256, address, address) {
        return (0, 0, 0, 6, address(token), address(0));
    }

    function getMinAccountOpenCNS() external view returns (uint256) {
        return minAccountOpen;
    }

    function createAccount(uint256 amount) external returns (uint256 id) {
        if (accountIdOf[msg.sender] != 0) revert Unsupported();
        id = nextAccountId++;
        accountAddr[id] = msg.sender;
        accountIdOf[msg.sender] = id;
        token.safeTransferFrom(msg.sender, address(this), amount);
        balance[id] = amount;
    }

    function depositCollateral(uint256 amount) external {
        uint256 id = _id();
        token.safeTransferFrom(msg.sender, address(this), amount);
        balance[id] += amount;
    }

    function withdrawCollateral(uint256 amount) external {
        uint256 id = _id();
        if (balance[id] < amount) revert Insufficient();
        balance[id] -= amount;
        token.safeTransfer(msg.sender, amount);
    }

    function execOrder(IExchange.OrderDesc calldata o) external returns (IExchange.OrderSignature memory sig) {
        _exec(_id(), o);
        sig = IExchange.OrderSignature(o.perpId, 0);
    }

    function execOrders(IExchange.OrderDesc[] calldata orders, bool)
        external
        returns (IExchange.OrderSignature[] memory sigs)
    {
        uint256 id = _id();
        sigs = new IExchange.OrderSignature[](orders.length);
        for (uint256 i; i < orders.length; ++i) {
            _exec(id, orders[i]);
            sigs[i] = IExchange.OrderSignature(orders[i].perpId, 0);
        }
    }

    function setMarkInvalid(uint256 perpId, bool invalid) external {
        markInvalid[perpId] = invalid;
    }

    function getAccountById(uint256 id) external view returns (IExchange.AccountInfo memory a) {
        a.accountId = id;
        a.balanceCNS = balance[id];
        a.accountAddr = accountAddr[id];
    }

    function getPositionV2(uint256 perpId, uint256 id)
        external
        view
        returns (IExchange.PositionInfoV2 memory info, uint256 markPNS, bool valid)
    {
        Position memory p = _pos[perpId][id];
        info.accountId = id;
        info.positionType = IExchange.PositionEnum.wrap(p.side);
        info.depositCNS = p.deposit;
        info.pricePNS = p.entry;
        info.lotLNS = p.lot;
        info.pnlCNS = _pnl(p, mark[perpId]);
        info.deltaPnlCNS = info.pnlCNS;
        return (info, mark[perpId], !markInvalid[perpId]);
    }

    function getPerpetualInfoV2(uint256 perpId) external view returns (IExchange.PerpetualInfoV2 memory info) {
        uint256 m = mark[perpId];
        info.priceDecimals = 1;
        info.lotDecimals = 5;
        info.markPNS = m;
        info.markTimestamp = markTs[perpId];
        info.minAskPriceONS = (m * (10_000 + spreadBps)) / 10_000;
        info.maxBidPriceONS = (m * (10_000 - spreadBps)) / 10_000;
        info.status = IExchange.PerpStatusEnum.wrap(paused[perpId] ? 0 : 4); // 4 as observed on Perpl testnet
        info.insuranceBalanceCNS = insurance[perpId];
        info.longOpenInterestLNS = openInterest[perpId];
        info.shortOpenInterestLNS = openInterest[perpId];
    }

    // ------------------------------------------------------------ internals

    function _id() internal view returns (uint256 id) {
        id = accountIdOf[msg.sender];
        if (id == 0) revert NoAccount();
    }

    function _pnl(Position memory p, uint256 m) internal pure returns (int256) {
        if (p.lot == 0) return 0;
        int256 diff = int256(m) - int256(p.entry);
        return p.side == 0 ? diff * int256(p.lot) : -diff * int256(p.lot);
    }

    function _exec(uint256 id, IExchange.OrderDesc calldata o) internal {
        uint8 t = IExchange.OrderDescEnum.unwrap(o.orderType);
        if (t > 3) revert Unsupported();
        bool buys = t == 0 || t == 3;
        uint256 m = mark[o.perpId];
        uint256 fill = buys ? (m * (10_000 + spreadBps)) / 10_000 : (m * (10_000 - spreadBps)) / 10_000;
        if (buys ? fill > o.pricePNS : fill < o.pricePNS) revert NotFilled();

        Position storage p = _pos[o.perpId][id];
        if (t <= 1) {
            uint8 side = t; // 0 long, 1 short
            if (p.lot != 0 && p.side != side) revert Unsupported(); // no inversion in the mock
            uint256 notional = fill * o.lotLNS;
            uint256 margin = (notional * 100) / o.leverageHdths;
            uint256 fee = (notional * takerFeeBps) / 10_000;
            if (balance[id] < margin + fee) revert Insufficient();
            balance[id] -= margin + fee;
            p.entry = p.lot == 0 ? fill : (p.entry * p.lot + fill * o.lotLNS) / (p.lot + o.lotLNS);
            p.side = side;
            p.lot += o.lotLNS;
            p.deposit += margin;
        } else {
            uint8 side = t == 2 ? 0 : 1;
            if (p.lot == 0 || p.side != side) revert Unsupported();
            uint256 lots = o.lotLNS < p.lot ? o.lotLNS : p.lot;
            uint256 depositPart = (p.deposit * lots) / p.lot;
            int256 diff = int256(fill) - int256(p.entry);
            int256 realized = side == 0 ? diff * int256(lots) : -diff * int256(lots);
            int256 back = int256(depositPart) + realized - int256((fill * lots * takerFeeBps) / 10_000);
            if (back > 0) balance[id] += uint256(back);
            else badDebt += uint256(-back);
            p.deposit -= depositPart;
            p.lot -= lots;
            if (p.lot == 0) delete _pos[o.perpId][id];
        }
    }
}
