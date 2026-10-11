// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";

interface IOwned {
    function owner() external view returns (address);
}

/// @title HistoryLinkRegistry
/// @notice A borrower proves that an existing Perpl account, and so its trading record, is theirs.
///         The wallet that controls the Perpl account signs an EIP-712 message naming the borrower;
///         the registry checks that wallet really controls the account on Perpl's exchange. Each
///         Perpl account can be linked to one borrower, permanently, so one record cannot back several
///         credit lines across different wallets.
/// @dev "Controls" means the account's address on Perpl is the signing wallet, or a contract (such as
///      a Perpl DelegatedAccount) whose `owner()` is the signing wallet. Accounts owned by Margin Line's
///      own CreditLines cannot be linked: their owner is a contract, which cannot produce an ECDSA
///      signature. Signatures carry a per-wallet nonce and a deadline.
contract HistoryLinkRegistry is EIP712 {
    bytes32 public constant LINK_TYPEHASH = keccak256("Link(address borrower,uint256 accountId,uint256 nonce,uint256 deadline)");
    uint256 public constant MAX_LINKS = 16;

    IExchange public immutable exchange;

    mapping(uint256 accountId => address borrower) public linkedTo;
    mapping(address wallet => uint256) public nonces;
    mapping(address borrower => uint256[]) internal _links;

    error Expired();
    error AlreadyLinked(uint256 accountId, address borrower);
    error UnknownAccount(uint256 accountId);
    error NotController(address wallet, uint256 accountId);
    error BadSignature();
    error TooManyLinks();

    event Linked(address indexed borrower, uint256 indexed accountId, address indexed wallet);

    constructor(IExchange exchange_) EIP712("MarginLine HistoryLink", "1") {
        exchange = exchange_;
    }

    /// @notice Link Perpl account `accountId` to the caller, with a signature from the wallet that
    ///         controls it.
    function link(uint256 accountId, address wallet, uint256 deadline, bytes calldata signature) external {
        if (block.timestamp > deadline) revert Expired();
        address existing = linkedTo[accountId];
        if (existing != address(0)) revert AlreadyLinked(accountId, existing);
        if (_links[msg.sender].length >= MAX_LINKS) revert TooManyLinks();
        if (!controls(wallet, accountId)) revert NotController(wallet, accountId);

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(LINK_TYPEHASH, msg.sender, accountId, nonces[wallet], deadline)));
        if (ECDSA.recover(digest, signature) != wallet) revert BadSignature();
        nonces[wallet]++;

        linkedTo[accountId] = msg.sender;
        _links[msg.sender].push(accountId);
        emit Linked(msg.sender, accountId, wallet);
    }

    /// @notice Whether `wallet` controls Perpl account `accountId`.
    function controls(address wallet, uint256 accountId) public view returns (bool) {
        address accountAddr = exchange.getAccountById(accountId).accountAddr;
        if (accountAddr == address(0)) revert UnknownAccount(accountId);
        if (accountAddr == wallet) return true;
        if (accountAddr.code.length == 0) return false;
        try IOwned(accountAddr).owner() returns (address o) {
            return o == wallet;
        } catch {
            return false;
        }
    }

    function linkedAccounts(address borrower) external view returns (uint256[] memory) {
        return _links[borrower];
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
