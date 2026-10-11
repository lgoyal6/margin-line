// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ILineRegistry {
    function isLine(address line) external view returns (bool);
}

/// @title CreditPool
/// @notice Holds lenders' AUSD in two tranches and lends it to CreditLines.
///
///         Junior takes losses first and earns whatever interest is left after the senior's target
///         rate and the reserve. Senior earns a target rate first and is hit only after the reserve
///         and the whole junior tranche are gone. A reserve fund, filled with a share of every interest
///         payment, absorbs losses before either tranche. Junior must stay at least `minJuniorBps` of
///         the pool, so senior always has a cushion beneath it.
///
///         Lenders hold shares of a tranche through a TrancheVault (an ERC-4626 per tranche); this
///         contract keeps the books and the cash. It tracks every line's outstanding principal, so a
///         line can never report more repaid or lost than it borrowed.
/// @dev Accounting identity, checked by the invariant suite:
///      seniorAssets + juniorAssets + reserve == AUSD held + principalOutstanding.
///      Interest is recognized when paid. The senior's target accrues on its share of deployed
///      principal as `seniorShortfall` and is paid first from later interest; it is never taken from
///      junior principal.
contract CreditPool is Ownable2Step {
    using SafeERC20 for IERC20;

    enum Tranche {
        Senior,
        Junior
    }

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    IERC20 public immutable asset;
    address public manager;
    address public seniorVault;
    address public juniorVault;

    uint256 public seniorAssets;
    uint256 public juniorAssets;
    uint256 public reserve;
    uint256 public principalOutstanding;
    mapping(address line => uint256) public principalOf;

    /// @notice Senior's target yield, and the senior yield accrued but not yet paid.
    uint16 public seniorAprBps;
    uint256 public seniorShortfall;
    uint40 public lastSeniorAccrual;

    uint16 public reserveBps; // share of every interest payment kept as reserve
    uint16 public minJuniorBps; // junior must be at least this share of senior + junior
    uint16 public maxUtilizationBps; // at most this share of the pool may be lent out

    uint256 public totalInterestEarned;
    uint256 public totalLosses;

    error OnlyManager();
    error OnlyLine();
    error OnlyVault();
    error AlreadySet();
    error ZeroAddress();
    error InvalidParams();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error UtilizationCap(uint256 utilizationBps, uint256 max);
    error JuniorBelowMinimum(uint256 juniorBps, uint256 min);
    error SettlementExceedsPrincipal(uint256 settled, uint256 principal);

    event Wired(address manager, address seniorVault, address juniorVault);
    event ParamsSet(uint16 seniorAprBps, uint16 reserveBps, uint16 minJuniorBps, uint16 maxUtilizationBps);
    event Deposited(Tranche indexed tranche, uint256 assets);
    event Withdrawn(Tranche indexed tranche, uint256 assets, address indexed to);
    event LineFunded(address indexed line, uint256 amount);
    event LineSettled(address indexed line, uint256 principalRepaid, uint256 interestPaid, uint256 principalLost);
    event InterestAllocated(uint256 toReserve, uint256 toSenior, uint256 toJunior);
    event LossAllocated(uint256 fromReserve, uint256 fromJunior, uint256 fromSenior);

    constructor(IERC20 asset_, address owner_) Ownable(owner_) {
        asset = asset_;
        _setParams(800, 1_000, 2_000, 9_000); // 8% senior target, 10% to reserve, 20% junior floor, 90% max lent
        lastSeniorAccrual = uint40(block.timestamp);
    }

    // ------------------------------------------------------------ admin

    function wire(address manager_, address seniorVault_, address juniorVault_) external onlyOwner {
        if (manager != address(0)) revert AlreadySet();
        if (manager_ == address(0) || seniorVault_ == address(0) || juniorVault_ == address(0)) revert ZeroAddress();
        manager = manager_;
        seniorVault = seniorVault_;
        juniorVault = juniorVault_;
        emit Wired(manager_, seniorVault_, juniorVault_);
    }

    function setParams(uint16 seniorAprBps_, uint16 reserveBps_, uint16 minJuniorBps_, uint16 maxUtilizationBps_)
        external
        onlyOwner
    {
        _accrueSenior();
        _setParams(seniorAprBps_, reserveBps_, minJuniorBps_, maxUtilizationBps_);
    }

    // ------------------------------------------------------------ views

    function idle() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function totalAssets() public view returns (uint256) {
        return idle() + principalOutstanding;
    }

    function trancheAssets(Tranche t) external view returns (uint256) {
        return t == Tranche.Senior ? seniorAssets : juniorAssets;
    }

    /// @notice Cash a tranche can withdraw right now: idle cash not held back as reserve, and for
    ///         junior, only down to the subordination floor.
    function withdrawable(Tranche t) public view returns (uint256) {
        uint256 cash = idle() > reserve ? idle() - reserve : 0;
        if (t == Tranche.Senior) return Math.min(cash, seniorAssets);
        // junior / (senior + junior) >= min  <=>  junior >= senior * min / (BPS - min)
        uint256 floor_ = minJuniorBps == 0 ? 0 : Math.mulDiv(seniorAssets, minJuniorBps, BPS - minJuniorBps, Math.Rounding.Ceil);
        uint256 free = juniorAssets > floor_ ? juniorAssets - floor_ : 0;
        return Math.min(cash, free);
    }

    /// @notice Largest deposit a tranche can take now. Junior is unlimited; senior may grow only
    ///         while junior stays at least `minJuniorBps` of the pool.
    function depositCap(Tranche t) external view returns (uint256) {
        if (t == Tranche.Junior || minJuniorBps == 0) return type(uint256).max;
        // junior * BPS / (senior + s + junior) >= min  <=>  s <= junior * BPS / min - senior - junior
        uint256 ceiling = Math.mulDiv(juniorAssets, BPS, minJuniorBps);
        uint256 used = seniorAssets + juniorAssets;
        return ceiling > used ? ceiling - used : 0;
    }

    function utilizationBps() public view returns (uint256) {
        uint256 total = seniorAssets + juniorAssets;
        return total == 0 ? 0 : Math.mulDiv(principalOutstanding, BPS, total);
    }

    function juniorBps() public view returns (uint256) {
        uint256 total = seniorAssets + juniorAssets;
        return total == 0 ? BPS : Math.mulDiv(juniorAssets, BPS, total);
    }

    // ------------------------------------------------------------ vault entry points

    /// @notice Called by a tranche vault after it has sent `assets` here.
    function onDeposit(Tranche t, uint256 assets) external {
        _onlyVault(t);
        _accrueSenior();
        if (t == Tranche.Senior) {
            seniorAssets += assets;
            uint256 jb = juniorBps();
            if (jb < minJuniorBps) revert JuniorBelowMinimum(jb, minJuniorBps); // senior cannot outgrow its cushion
        } else {
            juniorAssets += assets;
        }
        emit Deposited(t, assets);
    }

    /// @notice Called by a tranche vault to pay out a withdrawal.
    function onWithdraw(Tranche t, uint256 assets, address to) external {
        _onlyVault(t);
        _accrueSenior();
        uint256 available = withdrawable(t);
        if (assets > available) revert InsufficientLiquidity(assets, available);
        if (t == Tranche.Senior) seniorAssets -= assets;
        else juniorAssets -= assets;
        asset.safeTransfer(to, assets);
        emit Withdrawn(t, assets, to);
    }

    // ------------------------------------------------------------ lines

    /// @notice Send principal to a newly opened line, within the utilization cap.
    function fund(address line, uint256 amount) external {
        if (msg.sender != manager) revert OnlyManager();
        uint256 cash = idle() > reserve ? idle() - reserve : 0;
        if (amount > cash) revert InsufficientLiquidity(amount, cash);
        principalOf[line] += amount;
        principalOutstanding += amount;
        // Exact comparison: a floored bps figure would let 90.0001% through a 90% cap.
        if (principalOutstanding * BPS > (seniorAssets + juniorAssets) * maxUtilizationBps) {
            revert UtilizationCap(utilizationBps(), maxUtilizationBps);
        }
        asset.safeTransfer(line, amount);
        emit LineFunded(line, amount);
    }

    /// @notice Called by a line to repay and, at final settlement, to write off unrecovered principal.
    ///         Pulls `principalRepaid + interestPaid` from the line.
    function settle(uint256 principalRepaid, uint256 interestPaid, uint256 principalLost) external {
        if (!ILineRegistry(manager).isLine(msg.sender)) revert OnlyLine();
        uint256 principal = principalOf[msg.sender];
        uint256 reduced = principalRepaid + principalLost;
        if (reduced > principal) revert SettlementExceedsPrincipal(reduced, principal);
        _accrueSenior();

        principalOf[msg.sender] = principal - reduced;
        principalOutstanding -= reduced;
        if (interestPaid != 0) _allocateInterest(interestPaid);
        if (principalLost != 0) _allocateLoss(principalLost);

        uint256 incoming = principalRepaid + interestPaid;
        if (incoming != 0) asset.safeTransferFrom(msg.sender, address(this), incoming);
        emit LineSettled(msg.sender, principalRepaid, interestPaid, principalLost);
    }

    // ------------------------------------------------------------ internals

    function _allocateInterest(uint256 interest) internal {
        totalInterestEarned += interest;
        uint256 toReserve = Math.mulDiv(interest, reserveBps, BPS);
        uint256 rest = interest - toReserve;
        uint256 toSenior = Math.min(rest, seniorShortfall);
        seniorShortfall -= toSenior;
        uint256 toJunior = rest - toSenior;
        reserve += toReserve;
        seniorAssets += toSenior;
        juniorAssets += toJunior;
        emit InterestAllocated(toReserve, toSenior, toJunior);
    }

    /// @dev Reserve first, then junior, then senior.
    function _allocateLoss(uint256 loss) internal {
        totalLosses += loss;
        uint256 fromReserve = Math.min(loss, reserve);
        reserve -= fromReserve;
        loss -= fromReserve;
        uint256 fromJunior = Math.min(loss, juniorAssets);
        juniorAssets -= fromJunior;
        loss -= fromJunior;
        uint256 fromSenior = Math.min(loss, seniorAssets);
        seniorAssets -= fromSenior;
        emit LossAllocated(fromReserve, fromJunior, fromSenior);
    }

    /// @dev The senior's target accrues on the senior's share of principal actually lent out, not on
    ///      idle cash, so an underused pool does not build a claim it could never have earned. It is a
    ///      claim on future interest, paid ahead of junior.
    function _accrueSenior() internal {
        uint256 dt = block.timestamp - lastSeniorAccrual;
        uint256 total = seniorAssets + juniorAssets;
        if (dt != 0 && total != 0 && principalOutstanding != 0 && seniorAprBps != 0) {
            uint256 seniorDeployed = Math.mulDiv(principalOutstanding, seniorAssets, total);
            seniorShortfall += Math.mulDiv(seniorDeployed, uint256(seniorAprBps) * dt, BPS * YEAR);
        }
        lastSeniorAccrual = uint40(block.timestamp);
    }

    function _onlyVault(Tranche t) internal view {
        if (msg.sender != (t == Tranche.Senior ? seniorVault : juniorVault)) revert OnlyVault();
    }

    function _setParams(uint16 seniorAprBps_, uint16 reserveBps_, uint16 minJuniorBps_, uint16 maxUtilizationBps_)
        internal
    {
        if (seniorAprBps_ > 5_000 || reserveBps_ > 5_000 || minJuniorBps_ >= BPS || maxUtilizationBps_ > BPS
                || maxUtilizationBps_ == 0) revert InvalidParams();
        seniorAprBps = seniorAprBps_;
        reserveBps = reserveBps_;
        minJuniorBps = minJuniorBps_;
        maxUtilizationBps = maxUtilizationBps_;
        emit ParamsSet(seniorAprBps_, reserveBps_, minJuniorBps_, maxUtilizationBps_);
    }
}
