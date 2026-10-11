// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {CreditPool} from "./CreditPool.sol";
import {CreditManager} from "./CreditManager.sol";
import {TradeGuard} from "./TradeGuard.sol";
import {CircuitBreaker} from "./CircuitBreaker.sol";
import {ICreditManager} from "./CreditLine.sol";

/// @title RiskCurator
/// @notice The one admin of a market (pool, manager, guard, breaker). The curator can make the
///         market safer at once, but any change that adds risk for lenders waits out a public
///         timelock, during which lenders can leave and the guardian can veto it.
///
///         Instant (tightening): a lower concentration limit, a lower exposure cap, disallowing a
///         market, lower leverage or a narrower band, stricter health thresholds, a lower deposit
///         multiple, a higher junior floor, a lower utilization cap, a larger reserve share, a higher
///         insurance floor, removing the underwriter, and pausing.
///         Timelocked (everything else): each of those in the other direction, unpausing, the
///         senior rate, installing an underwriter, the peg feed, ownership of any component, the guardian, and shortening
///         the timelock itself.
/// @dev Pattern after MetaMorpho's curator/guardian split. A queued change is identified by the
///      hash of its target and calldata, and anyone may execute it once it matures.
contract RiskCurator is Ownable2Step {
    uint256 public constant MIN_TIMELOCK = 1 days;
    uint256 public constant MAX_TIMELOCK = 30 days;

    CreditPool public immutable pool;
    CreditManager public immutable manager;
    TradeGuard public immutable guard;
    CircuitBreaker public immutable breaker;

    address public guardian;
    /// @notice The market's ScoreOracle, wired once by the factory that deployed this curator.
    address public scoreOracle;
    address internal immutable _deployer;
    uint256 public timelock;
    mapping(bytes32 id => uint256 validAt) public pending;

    error OnlyGuardianOrOwner();
    error NotPending(bytes32 id);
    error AlreadyPending(bytes32 id);
    error Timelocked(bytes32 id, uint256 validAt);
    error NotTightening();
    error UnknownTarget(address target);
    error InvalidTimelock();
    error CallFailed(bytes reason);

    event Queued(bytes32 indexed id, address indexed target, bytes data, uint256 validAt);
    event Executed(bytes32 indexed id, address indexed target, bytes data);
    event Revoked(bytes32 indexed id, address indexed by);
    event Tightened(address indexed target, bytes data);
    event TimelockSet(uint256 timelock);
    event GuardianSet(address guardian);
    event ScoreOracleWired(address oracle);

    constructor(
        CreditPool pool_,
        CreditManager manager_,
        TradeGuard guard_,
        CircuitBreaker breaker_,
        address owner_,
        address guardian_,
        uint256 timelock_
    ) Ownable(owner_) {
        if (timelock_ < MIN_TIMELOCK || timelock_ > MAX_TIMELOCK) revert InvalidTimelock();
        pool = pool_;
        manager = manager_;
        guard = guard_;
        breaker = breaker_;
        guardian = guardian_;
        timelock = timelock_;
        _deployer = msg.sender;
    }

    /// @notice One-time wiring by the deploying factory: the oracle is created after this curator,
    ///         since it reads the guardian from here. After this, oracle settings go through `submit`.
    function wireScoreOracle(address oracle) external {
        if (msg.sender != _deployer || scoreOracle != address(0)) revert OwnableUnauthorizedAccount(msg.sender);
        scoreOracle = oracle;
        emit ScoreOracleWired(oracle);
    }

    // ------------------------------------------------------------ taking ownership

    /// @notice Accept ownership of a component after its current owner nominated this contract.
    ///         Anyone can call: completing a nomination only ever hands control to this contract.
    function acceptOwnershipOf(Ownable2Step component) external {
        _requireKnown(address(component));
        component.acceptOwnership();
    }

    // ------------------------------------------------------------ instant tightening

    function tightenMaxLine(uint16 bps) external onlyOwner {
        if (bps > manager.maxLineBps()) revert NotTightening();
        _tighten(address(manager), abi.encodeCall(CreditManager.setMaxLineBps, (bps)));
    }

    function tightenExposureCap(uint256 perpId, uint256 cap) external onlyOwner {
        uint256 current = guard.exposureCap(perpId);
        if (cap == 0 || (current != 0 && cap > current)) revert NotTightening();
        _tighten(address(guard), abi.encodeCall(TradeGuard.setExposureCap, (perpId, cap)));
    }

    /// @notice Disallow a market, or keep it allowed with lower leverage and a narrower band.
    function tightenMarket(uint256 perpId, bool allowed, uint16 maxLeverageHdths, uint16 bandBps) external onlyOwner {
        (bool isAllowed, uint16 lev, uint16 band) = guard.markets(perpId);
        if (allowed && (!isAllowed || maxLeverageHdths > lev || bandBps > band)) revert NotTightening();
        _tighten(address(guard), abi.encodeCall(TradeGuard.setMarket, (perpId, allowed, maxLeverageHdths, bandBps)));
    }

    function tightenRisk(ICreditManager.RiskParams calldata p, uint16 maxLeverageOnDepositBps) external onlyOwner {
        ICreditManager.RiskParams memory c = manager.riskParams();
        if (
            p.freezeHealthBps < c.freezeHealthBps || p.openHealthBps < c.openHealthBps
                || p.sweepHealthBps < c.sweepHealthBps || maxLeverageOnDepositBps > manager.maxLeverageOnDepositBps()
        ) revert NotTightening();
        _tighten(address(manager), abi.encodeCall(CreditManager.setRiskParams, (p, maxLeverageOnDepositBps)));
    }

    /// @notice Raise the junior floor or the reserve share, or lower the utilization cap. The senior
    ///         rate moves value between tranches in either direction, so it cannot change here.
    function tightenPool(uint16 reserveBps, uint16 minJuniorBps, uint16 maxUtilizationBps) external onlyOwner {
        if (
            reserveBps < pool.reserveBps() || minJuniorBps < pool.minJuniorBps()
                || maxUtilizationBps > pool.maxUtilizationBps()
        ) revert NotTightening();
        _tighten(
            address(pool),
            abi.encodeCall(CreditPool.setParams, (pool.seniorAprBps(), reserveBps, minJuniorBps, maxUtilizationBps))
        );
    }

    function tightenInsuranceFloor(uint16 bps) external onlyOwner {
        if (bps < breaker.minInsuranceBps()) revert NotTightening();
        _tighten(address(breaker), abi.encodeCall(CircuitBreaker.setMinInsuranceBps, (bps)));
    }

    /// @notice Remove the underwriter at once, e.g. if its key is compromised. Approvals it already
    ///         issued stay usable, so pair this with `pause` to stop new lines too. Installing an
    ///         underwriter is timelocked.
    function revokeUnderwriter() external onlyOwner {
        _tighten(address(manager), abi.encodeCall(CreditManager.setUnderwriter, (address(0))));
    }

    /// @notice Stop new risk across the market. The guardian can do this too, through the breaker's
    ///         pauser role, which this contract assigns to it.
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert OnlyGuardianOrOwner();
        breaker.pause();
    }

    /// @notice Lengthening the timelock is instant; shortening it is itself timelocked.
    function increaseTimelock(uint256 newTimelock) external onlyOwner {
        if (newTimelock <= timelock || newTimelock > MAX_TIMELOCK) revert InvalidTimelock();
        timelock = newTimelock;
        emit TimelockSet(newTimelock);
    }

    // ------------------------------------------------------------ timelocked

    /// @notice Queue any call on a component, or on this contract (guardian, timelock). It can run
    ///         after `timelock` seconds. Pending changes are public so lenders can react.
    function submit(address target, bytes calldata data) external onlyOwner returns (bytes32 id) {
        if (target != address(this)) _requireKnown(target);
        id = keccak256(abi.encode(target, data));
        if (pending[id] != 0) revert AlreadyPending(id);
        uint256 validAt = block.timestamp + timelock;
        pending[id] = validAt;
        emit Queued(id, target, data, validAt);
    }

    /// @notice Run a matured change. Anyone can call.
    function execute(address target, bytes calldata data) external {
        bytes32 id = keccak256(abi.encode(target, data));
        uint256 validAt = pending[id];
        if (validAt == 0) revert NotPending(id);
        if (block.timestamp < validAt) revert Timelocked(id, validAt);
        delete pending[id];
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
        emit Executed(id, target, data);
    }

    /// @notice Cancel a queued change. The guardian's veto, also available to the owner.
    function revoke(bytes32 id) external {
        if (msg.sender != owner() && msg.sender != guardian) revert OnlyGuardianOrOwner();
        if (pending[id] == 0) revert NotPending(id);
        delete pending[id];
        emit Revoked(id, msg.sender);
    }

    /// @notice Only reachable through `submit` + `execute`.
    function setGuardian(address guardian_) external {
        if (msg.sender != address(this)) revert OwnableUnauthorizedAccount(msg.sender);
        guardian = guardian_;
        breaker.setPauser(guardian_);
        emit GuardianSet(guardian_);
    }

    /// @notice Only reachable through `submit` + `execute`.
    function setTimelock(uint256 newTimelock) external {
        if (msg.sender != address(this)) revert OwnableUnauthorizedAccount(msg.sender);
        if (newTimelock < MIN_TIMELOCK || newTimelock > MAX_TIMELOCK) revert InvalidTimelock();
        timelock = newTimelock;
        emit TimelockSet(newTimelock);
    }

    // ------------------------------------------------------------ internals

    function _tighten(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
        emit Tightened(target, data);
    }

    function _requireKnown(address target) internal view {
        if (
            target != address(pool) && target != address(manager) && target != address(guard)
                && target != address(breaker) && (target != scoreOracle || target == address(0))
        ) {
            revert UnknownTarget(target);
        }
    }
}
