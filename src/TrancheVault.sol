// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CreditPool} from "./CreditPool.sol";

/// @title TrancheVault
/// @notice An ERC-4626 vault for one tranche of a CreditPool. Lenders deposit AUSD and hold shares
///         whose value tracks that tranche's assets (interest raises it, losses lower it).
///
///         Instant withdrawals are limited to what the pool can pay now (idle cash, and for junior the
///         subordination floor). Beyond that, a lender joins a first-come queue: their shares are held
///         in escrow and paid out, at the share price when paid, as loans are repaid. Anyone can
///         process the queue.
/// @dev Shares use OpenZeppelin's virtual offset against the first-depositor inflation attack.
contract TrancheVault is ERC4626, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Request {
        address owner;
        uint256 shares;
    }

    CreditPool public immutable pool;
    CreditPool.Tranche public immutable tranche;

    Request[] public queue;
    uint256 public head; // next request to pay
    uint256 public queuedShares;

    error NotRequestOwner();
    error AlreadyProcessed();
    error ZeroShares();

    event WithdrawalQueued(uint256 indexed id, address indexed owner, uint256 shares);
    event WithdrawalPaid(uint256 indexed id, address indexed owner, uint256 shares, uint256 assets);
    event WithdrawalCancelled(uint256 indexed id, address indexed owner, uint256 shares);

    constructor(CreditPool pool_, CreditPool.Tranche tranche_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(pool_.asset())
    {
        pool = pool_;
        tranche = tranche_;
    }

    function totalAssets() public view override returns (uint256) {
        return pool.trancheAssets(tranche);
    }

    function maxDeposit(address) public view override returns (uint256) {
        return pool.depositCap(tranche);
    }

    function maxMint(address) public view override returns (uint256) {
        uint256 cap = pool.depositCap(tranche);
        return cap == type(uint256).max ? cap : _convertToShares(cap, Math.Rounding.Floor);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner_), instantLiquidity());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner_), _convertToShares(instantLiquidity(), Math.Rounding.Floor));
    }

    /// @notice Cash available to withdraw instantly. The queue is paid first: liquidity owed to queued
    ///         requests is not available to lenders who did not wait in line.
    function instantLiquidity() public view returns (uint256) {
        uint256 available = pool.withdrawable(tranche);
        uint256 owed = previewRedeem(queuedShares);
        return available > owed ? available - owed : 0;
    }

    // ------------------------------------------------------------ queue

    /// @notice Queue `shares` for withdrawal when liquidity is available. Shares move into escrow
    ///         here; they keep earning (or losing) with the tranche until paid.
    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 id) {
        if (shares == 0) revert ZeroShares();
        _transfer(msg.sender, address(this), shares);
        id = queue.length;
        queue.push(Request(msg.sender, shares));
        queuedShares += shares;
        emit WithdrawalQueued(id, msg.sender, shares);
    }

    /// @notice Cancel an unpaid request and get the shares back.
    function cancelRequest(uint256 id) external nonReentrant {
        Request storage r = queue[id];
        if (r.owner != msg.sender) revert NotRequestOwner();
        if (r.shares == 0) revert AlreadyProcessed();
        uint256 shares = r.shares;
        r.shares = 0;
        queuedShares -= shares;
        _transfer(address(this), msg.sender, shares);
        emit WithdrawalCancelled(id, msg.sender, shares);
    }

    /// @notice Pay queued requests in order while the pool has liquidity. Anyone can call.
    function processQueue(uint256 maxRequests) external nonReentrant returns (uint256 paid) {
        uint256 i = head;
        uint256 end = Math.min(queue.length, i + maxRequests);
        for (; i < end; ++i) {
            Request storage r = queue[i];
            if (r.shares == 0) continue; // cancelled
            uint256 assets = previewRedeem(r.shares);
            if (assets > pool.withdrawable(tranche)) break; // strict order: stop at the first we cannot pay
            uint256 shares = r.shares;
            address owner_ = r.owner;
            r.shares = 0;
            queuedShares -= shares;
            _burn(address(this), shares);
            pool.onWithdraw(tranche, assets, owner_);
            emit WithdrawalPaid(i, owner_, shares, assets);
            ++paid;
        }
        head = i;
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    // ------------------------------------------------------------ routing to the pool

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        IERC20(asset()).safeTransferFrom(caller, address(pool), assets);
        pool.onDeposit(tranche, assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (caller != owner_) _spendAllowance(owner_, caller, shares);
        _burn(owner_, shares);
        pool.onWithdraw(tranche, assets, receiver);
        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
