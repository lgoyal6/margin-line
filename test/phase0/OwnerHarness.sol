// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccount} from "perpl-delegated-account/DelegatedAccount.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";

/// @notice Minimal stand-in for CreditLine: it owns a Perpl DelegatedAccount and is the only
///         path to trade or withdraw. Phase 0 exists to prove this boundary on Perpl's real
///         contracts before any product code is written.
contract OwnerHarness {
    DelegatedAccount public immutable account;
    IERC20 public immutable collateral;

    constructor(DelegatedAccountFactory factory) {
        // No operator: the trader never gets direct access to the Perpl account.
        account = DelegatedAccount(factory.create(address(0), 0, ""));
        collateral = account.collateralToken();
    }

    function open(uint256 amountCNS) external {
        collateral.transfer(address(account), amountCNS);
        account.createAccount(amountCNS);
    }

    function trade(IExchange.OrderDesc calldata desc) external {
        (bool ok, bytes memory ret) = address(account).call(abi.encodeCall(IExchange.execOrder, (desc)));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function withdraw(uint256 amountCNS) external {
        account.withdrawCollateral(amountCNS);
    }
}
