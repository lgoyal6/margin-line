// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {CreditPool} from "./CreditPool.sol";
import {CreditManager} from "./CreditManager.sol";
import {CreditLine} from "./CreditLine.sol";
import {TradeGuard} from "./TradeGuard.sol";

/// @title RiskLens
/// @notice Read-only stress test for a market: "if BTC fell 30% right now, what would each tranche
///         lose?" Each open line's Perpl positions are revalued at shocked marks, the line is settled
///         the way CreditLine settles it (freeze bounty, then interest, then principal), and the
///         unrecovered principal runs through the pool's loss order (reserve, junior, senior).
/// @dev Conservative by construction: a position worth less than zero after the shock counts as
///      zero (isolated margin), and Perpl's 80% residual on liquidation is ignored. Lines are passed
///      in (an indexer finds them from LineOpened events) and each must belong to the manager.
contract RiskLens {
    uint256 internal constant BPS = 10_000;
    uint8 internal constant LONG = 0;

    struct Shock {
        uint256 perpId;
        int256 moveBps; // e.g. -3000 = price falls 30%
    }

    struct LineResult {
        address line;
        uint256 equityNow;
        uint256 equityAfter;
        uint256 debt;
        uint256 principalLost;
    }

    struct Result {
        LineResult[] lines;
        uint256 totalLoss;
        uint256 fromReserve;
        uint256 fromJunior;
        uint256 fromSenior;
        uint256 seniorAfter;
        uint256 juniorAfter;
        uint256 reserveAfter;
    }

    error NotALine(address line);

    function stress(CreditManager manager, address[] calldata lines, Shock[] calldata shocks)
        external
        view
        returns (Result memory r)
    {
        CreditPool pool = manager.pool();
        r.lines = new LineResult[](lines.length);
        for (uint256 i; i < lines.length; ++i) {
            if (!manager.isLine(lines[i])) revert NotALine(lines[i]);
            r.lines[i] = _stressLine(manager, CreditLine(lines[i]), shocks);
            r.totalLoss += r.lines[i].principalLost;
        }

        // The pool's loss order.
        uint256 loss = r.totalLoss;
        r.fromReserve = Math.min(loss, pool.reserve());
        loss -= r.fromReserve;
        r.fromJunior = Math.min(loss, pool.juniorAssets());
        loss -= r.fromJunior;
        r.fromSenior = Math.min(loss, pool.seniorAssets());
        r.reserveAfter = pool.reserve() - r.fromReserve;
        r.juniorAfter = pool.juniorAssets() - r.fromJunior;
        r.seniorAfter = pool.seniorAssets() - r.fromSenior;
    }

    function _stressLine(CreditManager manager, CreditLine line, Shock[] calldata shocks)
        internal
        view
        returns (LineResult memory lr)
    {
        lr.line = address(line);
        lr.debt = line.debt();
        lr.equityNow = line.equity();
        uint256 principal = line.principal();
        if (principal == 0) {
            lr.equityAfter = lr.equityNow;
            return lr;
        }

        // Cash held by the line and free collateral are unaffected by price.
        IExchange exchange = line.exchange();
        lr.equityAfter = line.asset().balanceOf(address(line));
        if (address(line.account()) != address(0)) {
            uint256 id = line.account().accountId();
            lr.equityAfter += exchange.getAccountById(id).balanceCNS;
            uint256[] memory ids = line.guard().marketIds();
            for (uint256 j; j < ids.length; ++j) {
                lr.equityAfter += _shockedValue(exchange, ids[j], id, _move(shocks, ids[j]));
            }
        }

        // Settle as CreditLine does: bounty, then interest, then principal.
        (uint16 bountyBps, uint256 maxBounty) = manager.freezeBounty();
        uint256 bounty = Math.min(Math.mulDiv(lr.debt, bountyBps, BPS), maxBounty);
        uint256 interest = lr.debt - principal;
        uint256 available = lr.equityAfter > bounty + interest ? lr.equityAfter - bounty - interest : 0;
        lr.principalLost = principal - Math.min(principal, available);
    }

    /// @dev Perpl's value of a position (deposit + pnl + premium pnl) plus the shock's effect on its
    ///      notional at the mark, floored at zero.
    function _shockedValue(IExchange exchange, uint256 perpId, uint256 accountId, int256 moveBps)
        internal
        view
        returns (uint256)
    {
        (IExchange.PositionInfoV2 memory pos,,) = exchange.getPositionV2(perpId, accountId);
        if (pos.lotLNS == 0) return 0;
        IExchange.PerpetualInfoV2 memory p = exchange.getPerpetualInfoV2(perpId);
        (,,, uint256 collateralDecimals,,) = exchange.getExchangeInfo();
        int256 notional =
            int256((p.markPNS * pos.lotLNS * 10 ** collateralDecimals) / 10 ** (p.priceDecimals + p.lotDecimals));
        int256 delta = (notional * moveBps) / int256(BPS);
        if (IExchange.PositionEnum.unwrap(pos.positionType) != LONG) delta = -delta;
        int256 value = int256(pos.depositCNS) + pos.pnlCNS + pos.premiumPnlCNS + delta;
        return value > 0 ? uint256(value) : 0;
    }

    function _move(Shock[] calldata shocks, uint256 perpId) internal pure returns (int256) {
        for (uint256 i; i < shocks.length; ++i) {
            if (shocks[i].perpId == perpId) return shocks[i].moveBps;
        }
        return 0;
    }
}
