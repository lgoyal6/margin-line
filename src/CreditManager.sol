// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {CreditPool} from "./CreditPool.sol";
import {CreditLine, ICreditManager} from "./CreditLine.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {CircuitBreaker} from "./CircuitBreaker.sol";
import {HistoryLinkRegistry} from "./HistoryLinkRegistry.sol";
import {ScoreOracle} from "./ScoreOracle.sol";
import {ScoreRules} from "./ScoreRules.sol";

/// @title CreditManager
/// @notice Approves borrowers, opens their lines, and holds the protocol-wide risk settings.
/// @dev In this phase an underwriter role records approvals; a later phase replaces it with
///      Merkle-committed score epochs. Lines are EIP-1167 clones because Monad charges for the gas
///      limit, which makes full deployments per borrower needlessly expensive.
contract CreditManager is ICreditManager, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using ScoreRules for ScoreRules.Features;

    struct Approval {
        uint128 limit; // max principal, AUSD units
        uint16 aprBps;
        uint40 expiry;
    }

    uint256 internal constant BPS = 10_000;

    CreditPool public immutable pool;
    IExchange public immutable exchange;
    IERC20 public immutable asset;
    IdentityRegistry public immutable identity;
    address public lineImplementation;
    /// @notice When true (the default) a borrower must have a passkey registered to open a line.
    bool public requirePasskey = true;
    CircuitBreaker public breaker;
    HistoryLinkRegistry public historyLinks;
    ScoreOracle public scoreOracle;
    /// @notice Freeze bounty: share of debt in basis points, and a cap in AUSD units.
    uint16 public freezeBountyBps = 50;
    uint256 public maxFreezeBounty = 250e6;
    uint16 public constant MAX_FREEZE_BOUNTY_BPS = 200;

    address public underwriter;
    /// @notice Principal may be at most this multiple of the borrower's own deposit (first loss).
    uint16 public maxLeverageOnDepositBps;
    /// @notice Concentration limit: one line may borrow at most this share of the pool's lender
    ///         capital (senior + junior), so a single default cannot wipe out the junior tranche.
    uint16 public maxLineBps = 2_500;
    RiskParams internal _risk;

    mapping(address borrower => Approval) public approvals;
    mapping(address borrower => address line) public activeLine;
    mapping(address line => bool) public isLine;

    error OnlyUnderwriter();
    error ImplementationAlreadySet();
    error NoApproval();
    error ApprovalExpired();
    error AboveLimit(uint256 requested, uint256 limit);
    error DepositTooSmall(uint256 principal, uint256 deposit);
    error BelowVenueMinimum(uint256 amount, uint256 minimum);
    error LineAlreadyOpen(address line);
    error OnlyLine();
    error InvalidParams();
    error ZeroAddress();
    error PasskeyRequired();
    error BreakerAlreadySet();
    error NewRiskBlocked(CircuitBreaker.Reason reason);
    error LineTooLarge(uint256 principal, uint256 max);
    error ScoreOracleNotSet();
    error ScoreLeafInconsistent();
    error ScoreNotFinalized();
    error UnlinkedHistory(uint256 accountId);
    error ScoreProofInvalid();
    error ScoreExpired();

    event UnderwriterSet(address indexed underwriter);
    event MaxLineBpsSet(uint16 bps);
    event LineImplementationSet(address implementation);
    event ScoreOracleSet(address oracle);
    event HistoryLinksSet(address links);
    event RiskParamsSet(uint16 freezeHealthBps, uint16 openHealthBps, uint16 sweepHealthBps, uint16 maxLeverageOnDepositBps);
    event Approved(address indexed borrower, uint128 limit, uint16 aprBps, uint40 expiry);
    event LineOpened(address indexed borrower, address indexed line, uint256 deposit, uint256 principal);
    event LineClosed(address indexed borrower, address indexed line);
    event RequirePasskeySet(bool required);
    event BreakerSet(address breaker);
    event FreezeBountySet(uint16 bps, uint256 max);

    constructor(CreditPool pool_, IExchange exchange_, IdentityRegistry identity_, address owner_) Ownable(owner_) {
        pool = pool_;
        exchange = exchange_;
        identity = identity_;
        asset = IERC20(pool_.asset());
        _setRisk(RiskParams({freezeHealthBps: 11_000, openHealthBps: 13_000, sweepHealthBps: 12_500}), 30_000);
    }

    /// @notice One-time wiring: the line implementation needs this manager's address at construction.
    function setLineImplementation(address implementation) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        if (lineImplementation != address(0)) revert ImplementationAlreadySet();
        lineImplementation = implementation;
        emit LineImplementationSet(implementation);
    }

    function setUnderwriter(address underwriter_) external onlyOwner {
        underwriter = underwriter_;
        emit UnderwriterSet(underwriter_);
    }

    function setRiskParams(RiskParams calldata params, uint16 maxLeverageOnDepositBps_) external onlyOwner {
        _setRisk(params, maxLeverageOnDepositBps_);
    }

    /// @notice One-time wiring of the circuit breaker.
    function setBreaker(CircuitBreaker breaker_) external onlyOwner {
        if (address(breaker_) == address(0)) revert ZeroAddress();
        if (address(breaker) != address(0)) revert BreakerAlreadySet();
        breaker = breaker_;
        emit BreakerSet(address(breaker_));
    }

    function setScoreOracle(ScoreOracle oracle_) external onlyOwner {
        if (address(scoreOracle) != address(0)) revert InvalidParams();
        scoreOracle = oracle_;
        emit ScoreOracleSet(address(oracle_));
    }

    function setHistoryLinks(HistoryLinkRegistry links_) external onlyOwner {
        if (address(historyLinks) != address(0)) revert InvalidParams();
        historyLinks = links_;
        emit HistoryLinksSet(address(links_));
    }

    function setFreezeBounty(uint16 bps, uint256 max) external onlyOwner {
        if (bps > MAX_FREEZE_BOUNTY_BPS) revert InvalidParams();
        freezeBountyBps = bps;
        maxFreezeBounty = max;
        emit FreezeBountySet(bps, max);
    }

    function freezeBounty() external view returns (uint16, uint256) {
        return (freezeBountyBps, maxFreezeBounty);
    }

    function setMaxLineBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > BPS) revert InvalidParams();
        maxLineBps = bps;
        emit MaxLineBpsSet(bps);
    }

    function setRequirePasskey(bool required) external onlyOwner {
        requirePasskey = required;
        emit RequirePasskeySet(required);
    }

    function riskParams() external view returns (RiskParams memory) {
        return _risk;
    }

    function approve(address borrower, uint128 limit, uint16 aprBps, uint40 expiry) external {
        if (msg.sender != underwriter) revert OnlyUnderwriter();
        approvals[borrower] = Approval(limit, aprBps, expiry);
        emit Approved(borrower, limit, aprBps, expiry);
    }

    /// @notice Open a line: the caller posts `deposit` of their own AUSD as first loss and borrows
    ///         `principal` from the pool. Both go into a Perpl account the new line owns.
    function openLine(uint256 deposit, uint256 principal) external nonReentrant returns (address line) {
        if (requirePasskey && !identity.hasPasskey(msg.sender)) revert PasskeyRequired();
        Approval memory a = approvals[msg.sender];
        if (a.limit == 0) revert NoApproval();
        if (block.timestamp > a.expiry) revert ApprovalExpired();
        if (principal > a.limit) revert AboveLimit(principal, a.limit);
        delete approvals[msg.sender];
        return _openLine(msg.sender, deposit, principal, a.aprBps);
    }

    function openLineWithScore(
        uint256 deposit,
        uint256 principal,
        uint256 epoch,
        uint256 perplAccount,
        ScoreRules.Features calldata features,
        uint256 limit,
        uint256 aprBps,
        bytes32[] calldata proof
    ) external nonReentrant returns (address line) {
        if (requirePasskey && !identity.hasPasskey(msg.sender)) revert PasskeyRequired();
        if (address(scoreOracle) == address(0) || address(historyLinks) == address(0)) revert ScoreOracleNotSet();
        if (!scoreOracle.isFinalized(epoch)) revert ScoreNotFinalized();
        if (!scoreOracle.epochIsFresh(epoch)) revert ScoreExpired();
        if (historyLinks.linkedTo(perplAccount) != msg.sender) revert UnlinkedHistory(perplAccount);
        if (!scoreOracle.verifyLeaf(epoch, perplAccount, features, limit, aprBps, proof)) revert ScoreProofInvalid();
        if (!features.eligible() || limit != features.limitFor() || aprBps != features.aprFor()) {
            revert ScoreLeafInconsistent();
        }
        if (principal > limit) revert AboveLimit(principal, limit);
        return _openLine(msg.sender, deposit, principal, uint16(aprBps));
    }

    function _openLine(address borrower, uint256 deposit, uint256 principal, uint16 aprBps_) internal returns (address line) {
        CircuitBreaker.Reason r = breaker.globalStatus();
        if (r != CircuitBreaker.Reason.None) revert NewRiskBlocked(r);
        if (principal * BPS > deposit * maxLeverageOnDepositBps) revert DepositTooSmall(principal, deposit);
        uint256 maxLine = ((pool.seniorAssets() + pool.juniorAssets()) * maxLineBps) / BPS;
        if (principal > maxLine) revert LineTooLarge(principal, maxLine);
        uint256 minimum = exchange.getMinAccountOpenCNS();
        if (deposit + principal < minimum) revert BelowVenueMinimum(deposit + principal, minimum);
        address existing = activeLine[borrower];
        if (existing != address(0)) revert LineAlreadyOpen(existing);

        delete approvals[msg.sender]; // single use
        line = Clones.clone(lineImplementation);
        isLine[line] = true;
        activeLine[borrower] = line;

        asset.safeTransferFrom(borrower, line, deposit);
        pool.fund(line, principal);
        CreditLine(line).initialize(borrower, deposit, principal, aprBps_);
        emit LineOpened(borrower, line, deposit, principal);
    }

    function onLineClosed(address borrower) external {
        if (!isLine[msg.sender] || activeLine[borrower] != msg.sender) revert OnlyLine();
        delete activeLine[borrower];
        emit LineClosed(borrower, msg.sender);
    }

    function _setRisk(RiskParams memory p, uint16 maxLev) internal {
        // Freeze must sit above 1.0 so the line is frozen before it is insolvent, and below the
        // thresholds for opening risk and sweeping profit.
        if (p.freezeHealthBps <= BPS || p.openHealthBps <= p.freezeHealthBps || p.sweepHealthBps <= p.freezeHealthBps
                || maxLev == 0) revert InvalidParams();
        _risk = p;
        maxLeverageOnDepositBps = maxLev;
        emit RiskParamsSet(p.freezeHealthBps, p.openHealthBps, p.sweepHealthBps, maxLev);
    }
}
