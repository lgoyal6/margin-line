// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";
import {OwnerHarness} from "../phase0/OwnerHarness.sol";

/// @notice Pins down how Perpl values an open position, so CreditLine's equity formula is grounded in
///         the venue's own numbers: equity before a close should match the free balance after it,
///         minus the close fee and slippage. Testnet fork only.
contract PerplValuationTest is Test {
    IExchange constant EXCHANGE = IExchange(0x1964C32f0bE608E7D29302AFF5E61268E72080cc);
    DelegatedAccountFactory constant FACTORY = DelegatedAccountFactory(0xf42548Ccb3300Bc76c35dc2D347416db2E8d7209);
    IERC20 constant AUSD = IERC20(0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC);
    uint256 constant BTC = 16;

    function test_equityBeforeCloseMatchesBalanceAfter() public {
        if (block.chainid != 10143) vm.skip(true); // testnet addresses only
        OwnerHarness h = new OwnerHarness(FACTORY);
        vm.prank(address(EXCHANGE));
        AUSD.transfer(address(h), 1_000e6);
        h.open(500e6);
        uint256 id = h.account().accountId();

        IExchange.PerpetualInfoV2 memory p = EXCHANGE.getPerpetualInfoV2(BTC);
        h.trade(_order(0, ((p.minAskPriceONS + p.basePricePNS) * 1005) / 1000, 200, 300));

        IExchange.AccountInfo memory acct = EXCHANGE.getAccountById(id);
        (IExchange.PositionInfoV2 memory pos, uint256 mark, bool markValid) = EXCHANGE.getPositionV2(BTC, id);
        int256 positionValue = int256(pos.depositCNS) + pos.pnlCNS + pos.premiumPnlCNS;
        int256 equity = int256(acct.balanceCNS) + positionValue;
        console2.log("balance after open", acct.balanceCNS);
        console2.log("locked", acct.lockedBalanceCNS);
        console2.log("position deposit", pos.depositCNS);
        console2.log("pnl", pos.pnlCNS);
        console2.log("deltaPnl", pos.deltaPnlCNS);
        console2.log("premiumPnl", pos.premiumPnlCNS);
        console2.log("entry", pos.pricePNS);
        console2.log("mark", mark);
        console2.log("markValid", markValid);
        console2.log("equity", equity);

        p = EXCHANGE.getPerpetualInfoV2(BTC);
        h.trade(_order(2, ((p.maxBidPriceONS + p.basePricePNS) * 995) / 1000, pos.lotLNS, 300));
        uint256 after_ = EXCHANGE.getAccountById(id).balanceCNS;
        console2.log("balance after close", after_);

        // Close costs a taker fee (3.45 bps base) plus crossing the spread; allow 0.5% of notional.
        uint256 notional = (mark * pos.lotLNS * 1e6) / (10 ** (1 + 5)); // priceDecimals 1, lotDecimals 5, AUSD 6dp
        assertApproxEqAbs(int256(after_), equity, notional / 200, "equity formula disagrees with realized balance");
    }

    function _order(uint8 t, uint256 price, uint256 lot, uint256 lev) internal pure returns (IExchange.OrderDesc memory d) {
        d.perpId = BTC;
        d.orderType = IExchange.OrderDescEnum.wrap(t);
        d.pricePNS = price;
        d.lotLNS = lot;
        d.immediateOrCancel = true;
        d.maxMatches = 50;
        d.leverageHdths = lev;
        d.maxNegPnlCollatBPS = 1000;
    }
}
