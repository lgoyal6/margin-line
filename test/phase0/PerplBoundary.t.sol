// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccount} from "perpl-delegated-account/DelegatedAccount.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";
import {OwnerHarness} from "./OwnerHarness.sol";

/// @notice Phase 0 gate: a contract can own a Perpl account, trade on Perpl's real order book
///         through the owner path, and nobody else can withdraw. Runs against a local fork of Monad
///         testnet or mainnet with Perpl's deployed Exchange and DelegatedAccountFactory. Forks only:
///         nothing here sends a real transaction.
contract PerplBoundaryTest is Test {
    // Perpl deployments (PerplFoundation/delegated-account README, verified onchain).
    IExchange EXCHANGE;
    DelegatedAccountFactory FACTORY;
    IERC20 AUSD;
    uint256 BTC;

    // Order types from Perpl's SDK (crates/sdk/src/types/request.rs).
    uint8 constant OPEN_LONG = 0;
    uint8 constant CLOSE_LONG = 2;

    OwnerHarness harness;
    address trader = makeAddr("trader");

    function setUp() public {
        // Foundry selects its Monad EVM only for CLI forks: run with --fork-url <monad rpc>.
        if (block.chainid == 10143) {
            EXCHANGE = IExchange(0x1964C32f0bE608E7D29302AFF5E61268E72080cc);
            FACTORY = DelegatedAccountFactory(0xf42548Ccb3300Bc76c35dc2D347416db2E8d7209);
            AUSD = IERC20(0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC);
            BTC = 16;
        } else if (block.chainid == 143) {
            EXCHANGE = IExchange(0x34B6552d57a35a1D042CcAe1951BD1C370112a6F);
            FACTORY = DelegatedAccountFactory(0xc535276e3e446e4F28D95ed27cCd5c32e4C8907a);
            AUSD = IERC20(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a);
            BTC = 1;
        } else {
            revert("run with --fork-url pointing at Monad testnet (10143) or mainnet (143)");
        }
        harness = new OwnerHarness(FACTORY);
        // AUSD uses non-standard storage, so `deal` cannot write balances. On this local fork only,
        // fund the harness from the largest aUSD holder (the Exchange's own collateral balance).
        vm.prank(address(EXCHANGE));
        AUSD.transfer(address(harness), 1_000e6);
        harness.open(500e6);
    }

    function test_contractOwnsPerplAccount() public view {
        DelegatedAccount account = harness.account();
        assertEq(account.owner(), address(harness), "harness must own the DelegatedAccount");
        assertGt(account.accountId(), 0, "Perpl account not created");
        IExchange.AccountInfo memory info = EXCHANGE.getAccountById(account.accountId());
        assertEq(info.accountAddr, address(account), "Perpl account must belong to the DelegatedAccount");
        assertEq(info.balanceCNS, 500e6, "deposit not credited");
    }

    function test_tradesOnRealOrderBookThroughOwnerPath() public {
        uint256 accountId = harness.account().accountId();
        uint256 ask = _bestAskPNS();

        // Buy 0.001 BTC at up to 0.5% above the best ask, immediate-or-cancel, 2x leverage.
        harness.trade(_order(OPEN_LONG, (ask * 1005) / 1000, 100, 200));
        (IExchange.PositionInfoV2 memory pos,,) = EXCHANGE.getPositionV2(BTC, accountId);
        assertGt(pos.lotLNS, 0, "long position not opened");

        // Close it reduce-only against the bid side.
        uint256 bid = _bestBidPNS();
        harness.trade(_order(CLOSE_LONG, (bid * 995) / 1000, pos.lotLNS, 200));
        (pos,,) = EXCHANGE.getPositionV2(BTC, accountId);
        assertEq(pos.lotLNS, 0, "position not closed");
    }

    function test_traderCannotWithdrawDirectly() public {
        DelegatedAccount account = harness.account();
        vm.startPrank(trader);
        vm.expectRevert();
        account.withdrawCollateral(1e6);
        vm.expectRevert(DelegatedAccount.OnlyOwnerOrOperator.selector);
        (bool ok,) = address(account).call(abi.encodeCall(IExchange.withdrawCollateral, (1e6)));
        ok;
        vm.stopPrank();
    }

    function test_traderCannotTradeAroundTheHarness() public {
        uint256 ask = _bestAskPNS();
        address account = address(harness.account());
        vm.prank(trader);
        vm.expectRevert(DelegatedAccount.OnlyOwnerOrOperator.selector);
        (bool ok,) = account.call(
            abi.encodeCall(IExchange.execOrder, (_order(OPEN_LONG, ask, 100, 200)))
        );
        ok;
    }

    function test_ownerWithdrawalReturnsFundsToOwner() public {
        uint256 before = AUSD.balanceOf(address(harness));
        harness.withdraw(100e6);
        assertEq(AUSD.balanceOf(address(harness)), before + 100e6, "withdrawal must land at the owner");
    }

    function _order(uint8 orderType, uint256 pricePNS, uint256 lotLNS, uint256 leverageHdths)
        internal
        view
        returns (IExchange.OrderDesc memory d)
    {
        d.perpId = BTC;
        d.orderType = IExchange.OrderDescEnum.wrap(orderType);
        d.pricePNS = pricePNS;
        d.lotLNS = lotLNS;
        d.immediateOrCancel = true;
        d.maxMatches = 50;
        d.leverageHdths = leverageHdths;
        d.maxNegPnlCollatBPS = 1000;
    }

    function _bestAskPNS() internal view returns (uint256) {
        IExchange.PerpetualInfoV2 memory p = EXCHANGE.getPerpetualInfoV2(BTC);
        return p.minAskPriceONS + p.basePricePNS;
    }

    function _bestBidPNS() internal view returns (uint256) {
        IExchange.PerpetualInfoV2 memory p = EXCHANGE.getPerpetualInfoV2(BTC);
        return p.maxBidPriceONS + p.basePricePNS;
    }
}
