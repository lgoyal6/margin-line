// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccount} from "perpl-delegated-account/DelegatedAccount.sol";
import {Fixture} from "../utils/Fixture.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {HistoryLinkRegistry} from "../../src/HistoryLinkRegistry.sol";

contract HistoryLinkRegistryTest is Fixture {
    HistoryLinkRegistry links;
    uint256 constant TRADER_KEY = 0xBEEF;
    address trader;
    address borrower = makeAddr("borrower");

    function setUp() public override {
        super.setUp();
        links = new HistoryLinkRegistry(IExchange(address(ex)));
        trader = vm.addr(TRADER_KEY);
    }

    function _eoaAccount(address wallet) internal returns (uint256 id) {
        ausd.mint(wallet, 100e6);
        vm.startPrank(wallet);
        ausd.approve(address(ex), 100e6);
        id = ex.createAccount(100e6);
        vm.stopPrank();
    }

    function _sign(uint256 key, address borrower_, uint256 id, uint256 deadline) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(links.LINK_TYPEHASH(), borrower_, id, links.nonces(vm.addr(key)), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", links.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_walletLinksItsOwnAccount() public {
        uint256 id = _eoaAccount(trader);
        bytes memory sig = _sign(TRADER_KEY, borrower, id, block.timestamp + 1 hours);
        vm.prank(borrower);
        links.link(id, trader, block.timestamp + 1 hours, sig);
        assertEq(links.linkedTo(id), borrower);
        assertEq(links.linkedAccounts(borrower).length, 1);
    }

    function test_ownerOfADelegatedAccountCanLinkIt() public {
        vm.prank(trader);
        DelegatedAccount da = DelegatedAccount(factory.create(address(0), 0, ""));
        ausd.mint(address(da), 100e6);
        vm.prank(trader);
        da.createAccount(100e6);
        uint256 id = da.accountId();
        bytes memory sig = _sign(TRADER_KEY, borrower, id, block.timestamp + 1 hours);
        vm.prank(borrower);
        links.link(id, trader, block.timestamp + 1 hours, sig);
        assertEq(links.linkedTo(id), borrower);
    }

    function test_cannotLinkSomeoneElsesAccount() public {
        uint256 id = _eoaAccount(makeAddr("real-owner"));
        bytes memory sig = _sign(TRADER_KEY, borrower, id, block.timestamp + 1 hours);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(HistoryLinkRegistry.NotController.selector, trader, id));
        links.link(id, trader, block.timestamp + 1 hours, sig);
    }

    function test_oneRecordBacksOneBorrowerForever() public {
        uint256 id = _eoaAccount(trader);
        bytes memory sig = _sign(TRADER_KEY, borrower, id, block.timestamp + 1 hours);
        vm.prank(borrower);
        links.link(id, trader, block.timestamp + 1 hours, sig);

        address second = makeAddr("second-wallet");
        sig = _sign(TRADER_KEY, second, id, block.timestamp + 1 hours);
        vm.prank(second);
        vm.expectRevert(abi.encodeWithSelector(HistoryLinkRegistry.AlreadyLinked.selector, id, borrower));
        links.link(id, trader, block.timestamp + 1 hours, sig);
    }

    function test_signatureMustNameTheCaller() public {
        uint256 id = _eoaAccount(trader);
        bytes memory sig = _sign(TRADER_KEY, borrower, id, block.timestamp + 1 hours);
        vm.prank(makeAddr("thief")); // replays the signature to claim the record
        vm.expectRevert(HistoryLinkRegistry.BadSignature.selector);
        links.link(id, trader, block.timestamp + 1 hours, sig);
    }

    function test_expiredSignatureRejected() public {
        uint256 id = _eoaAccount(trader);
        bytes memory sig = _sign(TRADER_KEY, borrower, id, block.timestamp - 1);
        vm.prank(borrower);
        vm.expectRevert(HistoryLinkRegistry.Expired.selector);
        links.link(id, trader, block.timestamp - 1, sig);
    }

    function test_marginLineOwnedAccountsCannotBeLinked() public {
        CreditLine line = _openLine(alice, 1_000e6, 2_000e6);
        uint256 id = line.account().accountId();
        // The account's owner is the CreditLine contract, which cannot sign.
        bytes memory sig = _sign(TRADER_KEY, borrower, id, block.timestamp + 1 hours);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(HistoryLinkRegistry.NotController.selector, trader, id));
        links.link(id, trader, block.timestamp + 1 hours, sig);
        assertFalse(links.controls(alice, id), "borrower does not control the line's account");
    }
}
