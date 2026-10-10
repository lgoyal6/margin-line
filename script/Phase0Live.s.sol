// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";
import {OwnerHarness} from "../test/phase0/OwnerHarness.sol";

interface IAgoraFaucet {
    function requestFunds(address receiver) external;
}

/// @notice Phase 0 on live Monad testnet: a contract creates and owns a Perpl account, opens and
///         closes a BTC position on Perpl's order book, then withdraws back to itself. Every step
///         leaves a transaction hash. Testnet only.
contract Phase0Live is Script {
    IExchange constant EXCHANGE = IExchange(0x1964C32f0bE608E7D29302AFF5E61268E72080cc);
    DelegatedAccountFactory constant FACTORY = DelegatedAccountFactory(0xf42548Ccb3300Bc76c35dc2D347416db2E8d7209);
    IERC20 constant AUSD = IERC20(0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC);
    IAgoraFaucet constant FAUCET = IAgoraFaucet(0xd236c18D274E54FAccC3dd9DDA4b27965a73ee6C);
    uint256 constant BTC = 16;
    uint256 constant DEPOSIT = 200e6;

    function run() external {
        require(block.chainid == 10143, "testnet only");
        address deployer = msg.sender;

        vm.startBroadcast();
        if (AUSD.balanceOf(deployer) < DEPOSIT) FAUCET.requestFunds(deployer);
        OwnerHarness harness = new OwnerHarness(FACTORY);
        AUSD.transfer(address(harness), DEPOSIT);
        harness.open(DEPOSIT);
        vm.stopBroadcast();

        uint256 accountId = harness.account().accountId();
        IExchange.PerpetualInfoV2 memory p = EXCHANGE.getPerpetualInfoV2(BTC);
        uint256 ask = p.minAskPriceONS + p.basePricePNS;

        vm.startBroadcast();
        harness.trade(_order(0, (ask * 1005) / 1000, 100));
        vm.stopBroadcast();

        (IExchange.PositionInfoV2 memory pos,,) = EXCHANGE.getPositionV2(BTC, accountId);
        require(pos.lotLNS > 0, "open failed");
        p = EXCHANGE.getPerpetualInfoV2(BTC);
        uint256 bid = p.maxBidPriceONS + p.basePricePNS;

        vm.startBroadcast();
        harness.trade(_order(2, (bid * 995) / 1000, pos.lotLNS));
        harness.withdraw(50e6);
        vm.stopBroadcast();

        console2.log("harness", address(harness));
        console2.log("delegatedAccount", address(harness.account()));
        console2.log("perplAccountId", accountId);
        console2.log("lotOpened", pos.lotLNS);
    }

    function _order(uint8 orderType, uint256 pricePNS, uint256 lotLNS)
        internal
        pure
        returns (IExchange.OrderDesc memory d)
    {
        d.perpId = BTC;
        d.orderType = IExchange.OrderDescEnum.wrap(orderType);
        d.pricePNS = pricePNS;
        d.lotLNS = lotLNS;
        d.immediateOrCancel = true;
        d.maxMatches = 50;
        d.leverageHdths = 200;
        d.maxNegPnlCollatBPS = 1000;
    }
}
