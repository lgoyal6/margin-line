// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccount} from "perpl-delegated-account/DelegatedAccount.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";
import {TradeGuard} from "./TradeGuard.sol";
import {CreditPool} from "./CreditPool.sol";
import {IdentityRegistry} from "./IdentityRegistry.sol";
import {CircuitBreaker} from "./CircuitBreaker.sol";

interface ICreditManager {
    struct RiskParams {
        uint16 freezeHealthBps; // below this anyone can freeze, e.g. 11_000 = 1.10
        uint16 openHealthBps; // minimum health after any risk-increasing trade
        uint16 sweepHealthBps; // minimum health after a profit sweep
    }

    function riskParams() external view returns (RiskParams memory);
    function onLineClosed(address borrower) external;
    function breaker() external view returns (CircuitBreaker);
    function freezeBounty() external view returns (uint16 bps, uint256 max);
}

/// @title CreditLine
/// @notice One per borrower, deployed as a clone by CreditManager. It creates and owns a Perpl
///         DelegatedAccount funded with the borrower's first-loss deposit plus the pool's loan.
///         The borrower is never an operator of that account: every trade comes through `trade`,
///         which applies TradeGuard's rules, and only this contract can withdraw.
///
///         Identity: actions that move money out to the borrower (profit sweep, closing, granting a
///         session key) need a fresh passkey approval from IdentityRegistry, bound to this line and
///         the exact arguments. A session key may only trade, within a per-order and a total notional
///         cap, until it expires; it can never sweep, close, repay from the account or grant keys.
/// @dev Health = equity / debt in basis points, where equity is AUSD held here + Perpl free balance +
///      the value of every position (margin + unrealized PnL + funding, floored at zero per position
///      because Perpl margin is isolated). This matches the venue's own numbers: see
///      test/fork/PerplValuation.t.sol. Debt = principal + accrued simple interest.
contract CreditLine is Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    enum State {
        Uninitialized,
        Active,
        Frozen,
        Closed
    }

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_HEALTH = type(uint256).max;
    uint256 public constant MAX_SESSION = 7 days;

    struct Session {
        uint40 expiry;
        uint96 maxOrderNotional; // per risk-increasing order, AUSD units
        uint96 remainingNotional; // across all risk-increasing orders
    }

    // Shared by every clone (set once on the implementation).
    address public immutable manager;
    CreditPool public immutable pool;
    TradeGuard public immutable guard;
    IExchange public immutable exchange;
    DelegatedAccountFactory public immutable accountFactory;
    IERC20 public immutable asset;
    IdentityRegistry public immutable identity;

    // Per line.
    address public borrower;
    DelegatedAccount public account;
    State public state;
    uint16 public aprBps;
    uint40 public lastAccrual;
    uint256 public principal;
    uint256 public interestOwed;
    uint256 public traderDeposit;
    mapping(address key => Session) public sessions;
    /// @notice Who froze the line, and the bounty they are owed at settlement.
    address public enforcer;
    uint256 public bountyOwed;

    error OnlyManager();
    error OnlyBorrower();
    error WrongState(State state);
    error HealthTooLow(uint256 healthBps, uint256 requiredBps);
    error Healthy(uint256 healthBps);
    error OpenPositions();
    error MarkInvalid(uint256 perpId);
    error ExchangeCallFailed(bytes reason);
    error ZeroAddress();
    error NotAuthorized();
    error SessionExpired();
    error SessionOrderTooLarge(uint256 notional, uint256 max);
    error SessionBudgetExceeded(uint256 notional, uint256 remaining);
    error InvalidSession();
    error NewRiskBlocked(CircuitBreaker.Reason reason);

    event Opened(address indexed borrower, address account, uint256 accountId, uint256 deposit, uint256 principal, uint16 aprBps);
    event Traded(uint256 orders, bool increasedRisk, uint256 healthBps);
    event ToppedUp(uint256 amount);
    event Repaid(address indexed payer, uint256 principalPaid, uint256 interestPaid);
    event Swept(address indexed to, uint256 amount, uint256 healthBps);
    event Frozen(address indexed by, uint256 healthBps, uint256 bounty);
    event BountyPaid(address indexed enforcer, uint256 amount);
    event Unwound(address indexed by, uint256 perpId, uint256 lots);
    event SessionGranted(address indexed key, uint40 expiry, uint96 maxOrderNotional, uint96 totalNotional);
    event SessionRevoked(address indexed key, address indexed by);
    event Closed(
        address indexed by,
        uint256 recovered,
        uint256 bountyPaid,
        uint256 principalRepaid,
        uint256 interestPaid,
        uint256 principalLost,
        uint256 toBorrower
    );

    constructor(
        address manager_,
        CreditPool pool_,
        TradeGuard guard_,
        IExchange exchange_,
        DelegatedAccountFactory accountFactory_,
        IERC20 asset_,
        IdentityRegistry identity_
    ) {
        manager = manager_;
        pool = pool_;
        guard = guard_;
        exchange = exchange_;
        accountFactory = accountFactory_;
        asset = asset_;
        identity = identity_;
        _disableInitializers();
    }

    modifier onlyBorrower() {
        if (msg.sender != borrower) revert OnlyBorrower();
        _;
    }

    modifier inState(State s) {
        if (state != s) revert WrongState(state);
        _;
    }

    /// @notice Called by CreditManager after it has sent `deposit + principal_` AUSD to this clone.
    function initialize(address borrower_, uint256 deposit, uint256 principal_, uint16 aprBps_)
        external
        initializer
    {
        if (msg.sender != manager) revert OnlyManager();
        if (borrower_ == address(0)) revert ZeroAddress();
        borrower = borrower_;
        traderDeposit = deposit;
        principal = principal_;
        aprBps = aprBps_;
        lastAccrual = uint40(block.timestamp);
        state = State.Active;

        // No operator: the borrower never gets direct access to the Perpl account.
        DelegatedAccount account_ = DelegatedAccount(accountFactory.create(address(0), 0, ""));
        account = account_;
        uint256 amount = deposit + principal_;
        asset.safeTransfer(address(account_), amount);
        account_.createAccount(amount);
        emit Opened(borrower_, address(account_), account_.accountId(), deposit, principal_, aprBps_);
    }

    // ---------------------------------------------------------------- borrower actions

    /// @notice Trade on Perpl through the guard. Callable by the borrower, or by a live session key
    ///         within its caps.
    function trade(IExchange.OrderDesc[] calldata orders) external nonReentrant inState(State.Active) {
        if (msg.sender != borrower) _spendSession(msg.sender, orders);
        _accrue();
        bool increasesRisk = guard.checkOrders(exchange, orders);
        if (increasesRisk) _requireMarketsOpen(orders);
        _exchangeCall(abi.encodeCall(IExchange.execOrders, (orders, true)));
        uint256 h = healthBps();
        if (increasesRisk) {
            _requireHealth(h, _params().openHealthBps);
            _requireExposureWithinCaps(orders);
        }
        emit Traded(orders.length, increasesRisk, h);
    }

    /// @notice Add the borrower's own AUSD to the Perpl account's free balance.
    function topUp(uint256 amount) external nonReentrant onlyBorrower inState(State.Active) {
        asset.safeTransferFrom(msg.sender, address(account), amount);
        _exchangeCall(abi.encodeCall(IExchange.depositCollateral, (amount)));
        emit ToppedUp(amount);
    }

    /// @notice Repay from the payer's wallet: interest first, then principal.
    function repay(uint256 amount) external nonReentrant {
        if (state != State.Active && state != State.Frozen) revert WrongState(state);
        _accrue();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        _payDebt(Math.min(amount, interestOwed + principal), msg.sender);
    }

    /// @notice Repay out of the Perpl account's free balance.
    function repayFromAccount(uint256 amount) external nonReentrant onlyBorrower inState(State.Active) {
        _accrue();
        amount = Math.min(amount, interestOwed + principal);
        account.withdrawCollateral(amount);
        _payDebt(amount, msg.sender);
    }

    /// @notice Withdraw profit to the borrower, only if the line stays comfortably healthy.
    function sweep(uint256 amount, IdentityRegistry.Proof calldata proof)
        external
        nonReentrant
        onlyBorrower
        inState(State.Active)
    {
        _requirePasskey(keccak256(abi.encode("sweep", amount)), proof);
        CircuitBreaker.Reason r = ICreditManager(manager).breaker().globalStatus();
        if (r != CircuitBreaker.Reason.None) revert NewRiskBlocked(r);
        _requireFreshMarks();
        _accrue();
        account.withdrawCollateral(amount);
        asset.safeTransfer(borrower, amount);
        uint256 h = healthBps();
        _requireHealth(h, _params().sweepHealthBps);
        emit Swept(borrower, amount, h);
    }

    /// @notice Let `key` trade for up to `MAX_SESSION`, capped per order and in total. Requires a
    ///         passkey approval of these exact limits. Re-granting replaces the previous limits.
    function grantSession(
        address key,
        uint40 expiry,
        uint96 maxOrderNotional,
        uint96 totalNotional,
        IdentityRegistry.Proof calldata proof
    ) external nonReentrant onlyBorrower inState(State.Active) {
        if (key == address(0) || key == borrower || expiry <= block.timestamp || expiry > block.timestamp + MAX_SESSION
                || maxOrderNotional == 0 || totalNotional < maxOrderNotional) revert InvalidSession();
        _requirePasskey(keccak256(abi.encode("grantSession", key, expiry, maxOrderNotional, totalNotional)), proof);
        sessions[key] = Session(expiry, maxOrderNotional, totalNotional);
        emit SessionGranted(key, expiry, maxOrderNotional, totalNotional);
    }

    /// @notice Revoke a session key. The borrower or the key itself can call; no passkey needed,
    ///         since revoking only removes power.
    function revokeSession(address key) external {
        if (msg.sender != borrower && msg.sender != key) revert NotAuthorized();
        delete sessions[key];
        emit SessionRevoked(key, msg.sender);
    }

    // ---------------------------------------------------------------- enforcement (anyone)

    /// @notice Freeze an unhealthy line. Anyone can call; once frozen the borrower cannot trade. The
    ///         caller earns a bounty (a share of the debt, capped), paid at settlement out of what the
    ///         line recovers. The borrower and its session keys never earn it.
    function freeze() external nonReentrant inState(State.Active) {
        _accrue();
        uint256 h = healthBps();
        if (h >= _params().freezeHealthBps) revert Healthy(h);
        state = State.Frozen;
        uint256 bounty;
        if (msg.sender != borrower && sessions[msg.sender].expiry == 0) {
            (uint16 bps, uint256 max) = ICreditManager(manager).freezeBounty();
            bounty = Math.min(Math.mulDiv(principal + interestOwed, bps, BPS), max);
            enforcer = msg.sender;
            bountyOwed = bounty;
        }
        emit Frozen(msg.sender, h, bounty);
    }

    /// @notice Close part or all of one position of a frozen line, reduce-only, at the edge of the
    ///         guard's price band. Anyone can call; it can only reduce risk.
    function unwind(uint256 perpId, uint256 maxLots) external nonReentrant inState(State.Frozen) {
        (IExchange.PositionInfoV2 memory pos,,) = exchange.getPositionV2(perpId, account.accountId());
        uint256 lots = Math.min(pos.lotLNS, maxLots);
        if (lots == 0) return;
        bool isLong = IExchange.PositionEnum.unwrap(pos.positionType) == 0;

        IExchange.OrderDesc memory o;
        o.perpId = perpId;
        o.orderType = IExchange.OrderDescEnum.wrap(isLong ? 2 : 3); // CloseLong / CloseShort
        o.pricePNS = guard.closePrice(exchange, perpId, isLong);
        o.lotLNS = lots;
        o.immediateOrCancel = true;
        o.maxMatches = 50;
        o.leverageHdths = 100;
        o.maxNegPnlCollatBPS = 10_000;
        _exchangeCall(abi.encodeCall(IExchange.execOrder, (o)));
        emit Unwound(msg.sender, perpId, lots);
    }

    /// @notice The borrower closes an active line with no open positions. Needs a passkey approval.
    function close(IdentityRegistry.Proof calldata proof) external nonReentrant onlyBorrower inState(State.Active) {
        _requirePasskey(keccak256("close"), proof);
        _settle();
    }

    /// @notice Anyone settles a frozen line once its positions are unwound.
    function settleFrozen() external nonReentrant inState(State.Frozen) {
        _settle();
    }

    /// @dev Pull everything out of Perpl, repay the pool, write off any principal that cannot be
    ///      recovered, pay the rest to the borrower.
    function _settle() internal {
        if (_hasOpenPositions()) revert OpenPositions();
        _accrue();

        uint256 free = exchange.getAccountById(account.accountId()).balanceCNS;
        if (free != 0) account.withdrawCollateral(free);
        uint256 recovered = asset.balanceOf(address(this));

        // Waterfall: enforcer bounty, interest, principal, then the borrower.
        uint256 bountyPaid = Math.min(recovered, bountyOwed);
        uint256 left = recovered - bountyPaid;
        uint256 interestPaid = Math.min(left, interestOwed);
        uint256 principalRepaid = Math.min(left - interestPaid, principal);
        uint256 principalLost = principal - principalRepaid;
        uint256 toBorrower = left - interestPaid - principalRepaid;

        principal = 0;
        interestOwed = 0;
        bountyOwed = 0;
        state = State.Closed;

        if (bountyPaid != 0) {
            asset.safeTransfer(enforcer, bountyPaid);
            emit BountyPaid(enforcer, bountyPaid);
        }
        asset.forceApprove(address(pool), principalRepaid + interestPaid);
        pool.settle(principalRepaid, interestPaid, principalLost);
        if (toBorrower != 0) asset.safeTransfer(borrower, toBorrower);
        ICreditManager(manager).onLineClosed(borrower);
        emit Closed(msg.sender, recovered, bountyPaid, principalRepaid, interestPaid, principalLost, toBorrower);
    }

    // ---------------------------------------------------------------- views

    /// @notice Principal plus interest, including interest accrued since the last update.
    function debt() public view returns (uint256) {
        return principal + interestOwed + _pendingInterest();
    }

    /// @notice Value of everything this line controls, using Perpl's own position accounting.
    function equity() public view returns (uint256 total) {
        total = asset.balanceOf(address(this));
        if (address(account) == address(0)) return total;
        uint256 id = account.accountId();
        total += exchange.getAccountById(id).balanceCNS;
        uint256[] memory ids = guard.marketIds();
        for (uint256 i; i < ids.length; ++i) {
            (IExchange.PositionInfoV2 memory pos,,) = exchange.getPositionV2(ids[i], id);
            if (pos.lotLNS == 0) continue;
            int256 value = int256(pos.depositCNS) + pos.pnlCNS + pos.premiumPnlCNS;
            if (value > 0) total += uint256(value);
        }
    }

    function healthBps() public view returns (uint256) {
        uint256 d = debt();
        if (d == 0) return MAX_HEALTH;
        return Math.mulDiv(equity(), BPS, d);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Borrowers without a registered passkey (only possible when the manager does not require
    ///      one) authenticate by wallet alone.
    function _requirePasskey(bytes32 action, IdentityRegistry.Proof calldata proof) internal {
        if (identity.hasPasskey(borrower)) identity.approve(borrower, action, proof);
    }

    function _requireMarketsOpen(IExchange.OrderDesc[] calldata orders) internal view {
        CircuitBreaker b = ICreditManager(manager).breaker();
        for (uint256 i; i < orders.length; ++i) {
            if (IExchange.OrderDescEnum.unwrap(orders[i].orderType) > 1) continue;
            CircuitBreaker.Reason r = b.marketStatus(exchange, orders[i].perpId);
            if (r != CircuitBreaker.Reason.None) revert NewRiskBlocked(r);
        }
    }

    /// @dev Profit is only withdrawn against prices Perpl stands behind: every market with an open
    ///      position needs a mark Perpl reports as valid and no older than the guard allows.
    function _requireFreshMarks() internal view {
        uint256 id = account.accountId();
        uint256[] memory ids = guard.marketIds();
        for (uint256 i; i < ids.length; ++i) {
            (IExchange.PositionInfoV2 memory pos,, bool valid) = exchange.getPositionV2(ids[i], id);
            if (pos.lotLNS == 0) continue;
            if (!valid) revert MarkInvalid(ids[i]);
            guard.requireFreshMark(exchange, ids[i]);
        }
    }

    function _requireExposureWithinCaps(IExchange.OrderDesc[] calldata orders) internal view {
        uint256 id = account.accountId();
        for (uint256 i; i < orders.length; ++i) {
            if (IExchange.OrderDescEnum.unwrap(orders[i].orderType) > 1) continue;
            (IExchange.PositionInfoV2 memory pos,,) = exchange.getPositionV2(orders[i].perpId, id);
            guard.checkExposure(exchange, orders[i].perpId, pos.lotLNS);
        }
    }

    function _spendSession(address key, IExchange.OrderDesc[] calldata orders) internal {
        Session storage s = sessions[key];
        if (s.expiry == 0) revert NotAuthorized();
        if (block.timestamp > s.expiry) revert SessionExpired();
        for (uint256 i; i < orders.length; ++i) {
            uint8 t = IExchange.OrderDescEnum.unwrap(orders[i].orderType);
            if (t > 1) continue; // closes reduce risk and are always allowed
            uint256 notional = guard.orderNotional(exchange, orders[i]);
            if (notional > s.maxOrderNotional) revert SessionOrderTooLarge(notional, s.maxOrderNotional);
            if (notional > s.remainingNotional) revert SessionBudgetExceeded(notional, s.remainingNotional);
            s.remainingNotional -= uint96(notional);
        }
    }

    function _payDebt(uint256 amount, address payer) internal {
        uint256 interestPaid = Math.min(amount, interestOwed);
        uint256 principalPaid = Math.min(amount - interestPaid, principal);
        interestOwed -= interestPaid;
        principal -= principalPaid;
        asset.forceApprove(address(pool), principalPaid + interestPaid);
        pool.settle(principalPaid, interestPaid, 0);
        emit Repaid(payer, principalPaid, interestPaid);
    }

    function _accrue() internal {
        interestOwed += _pendingInterest();
        lastAccrual = uint40(block.timestamp);
    }

    /// @dev Rounded up so rounding always favors the lender.
    function _pendingInterest() internal view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0 || principal == 0) return 0;
        return Math.mulDiv(principal, uint256(aprBps) * dt, BPS * YEAR, Math.Rounding.Ceil);
    }

    function _hasOpenPositions() internal view returns (bool) {
        uint256 id = account.accountId();
        uint256[] memory ids = guard.marketIds();
        for (uint256 i; i < ids.length; ++i) {
            (IExchange.PositionInfoV2 memory pos,,) = exchange.getPositionV2(ids[i], id);
            if (pos.lotLNS != 0) return true;
        }
        return false;
    }

    function _requireHealth(uint256 h, uint256 required) internal pure {
        if (h < required) revert HealthTooLow(h, required);
    }

    function _params() internal view returns (ICreditManager.RiskParams memory) {
        return ICreditManager(manager).riskParams();
    }

    /// @dev Forward a call to Perpl as the DelegatedAccount's owner (its fallback).
    function _exchangeCall(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(account).call(data);
        if (!ok) revert ExchangeCallFailed(ret);
    }
}
