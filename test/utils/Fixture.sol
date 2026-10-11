// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Passkeys} from "./Passkeys.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccount} from "perpl-delegated-account/DelegatedAccount.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {TrancheVault} from "../../src/TrancheVault.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {TradeGuard} from "../../src/TradeGuard.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";
import {CircuitBreaker} from "../../src/CircuitBreaker.sol";
import {MockPerplExchange} from "../mocks/MockPerplExchange.sol";

contract MockAUSD is ERC20("Mock AUSD", "AUSD") {
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Full protocol wired to a mock exchange, with Perpl's real DelegatedAccount and factory.
abstract contract Fixture is Passkeys {
    uint256 internal constant BTC = 1;
    uint256 internal constant BTC_PRICE = 1_000_000; // $100,000.0 with 1 price decimal

    MockAUSD internal ausd;
    MockPerplExchange internal ex;
    DelegatedAccountFactory internal factory;
    CreditPool internal pool;
    TrancheVault internal senior;
    TrancheVault internal junior;
    TradeGuard internal guard;
    CreditManager internal manager;
    CreditLine internal lineImpl;
    IdentityRegistry internal identity;
    CircuitBreaker internal breaker;

    address internal admin = makeAddr("admin");
    address internal underwriter = makeAddr("underwriter");
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        ausd = new MockAUSD();
        ex = new MockPerplExchange(IERC20(address(ausd)));
        ausd.mint(address(ex), 100_000_000e6); // venue liquidity that pays winners
        ex.setMark(BTC, BTC_PRICE);

        DelegatedAccount daImpl = new DelegatedAccount();
        factory = new DelegatedAccountFactory(address(daImpl), admin, address(ex));

        identity = new IdentityRegistry(RP_ID_HASH);
        pool = new CreditPool(IERC20(address(ausd)), admin);
        senior = new TrancheVault(pool, CreditPool.Tranche.Senior, "Margin Line Senior", "mlSR");
        junior = new TrancheVault(pool, CreditPool.Tranche.Junior, "Margin Line Junior", "mlJR");
        guard = new TradeGuard(admin, 120);
        manager = new CreditManager(pool, IExchange(address(ex)), identity, admin);
        lineImpl = new CreditLine(
            address(manager), pool, guard, IExchange(address(ex)), factory, IERC20(address(ausd)), identity
        );

        breaker = new CircuitBreaker(admin);
        vm.startPrank(admin);
        manager.setBreaker(breaker);
        pool.wire(address(manager), address(senior), address(junior));
        manager.setLineImplementation(address(lineImpl));
        manager.setUnderwriter(underwriter);
        guard.setMarket(BTC, true, 300, 50); // 3x max, 0.50% band
        vm.stopPrank();

        _lend(lender, 1_000_000e6);
    }

    /// @dev Lends into the junior tranche, which takes deposits without limit.
    function _lend(address who, uint256 amount) internal {
        _lendTo(junior, who, amount);
    }

    function _lendTo(TrancheVault vault, address who, uint256 amount) internal returns (uint256 shares) {
        ausd.mint(who, amount);
        vm.startPrank(who);
        ausd.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _approve(address borrower, uint128 limit) internal {
        vm.prank(underwriter);
        manager.approve(borrower, limit, 1_000, uint40(block.timestamp + 1 days)); // 10% APR
    }

    /// @dev Each test borrower's passkey private key is derived from their address.
    function _passkeyOf(address who) internal pure returns (uint256) {
        return (uint256(keccak256(abi.encode("passkey", who))) % (P256_N - 1)) + 1;
    }

    function _registerPasskey(address who) internal {
        if (identity.hasPasskey(who)) return;
        (bytes32 qx, bytes32 qy) = _pubkey(_passkeyOf(who));
        vm.prank(who);
        identity.registerFirstPasskey(qx, qy);
    }

    /// @dev The borrower's passkey approval of `action` on `line`.
    function _lineProof(CreditLine line, bytes32 action) internal view returns (IdentityRegistry.Proof memory) {
        address b = line.borrower();
        return _proof(identity, _passkeyOf(b), b, address(line), action);
    }

    function _sweep(CreditLine line, uint256 amount) internal {
        IdentityRegistry.Proof memory p = _lineProof(line, keccak256(abi.encode("sweep", amount)));
        address b = line.borrower();
        vm.prank(b);
        line.sweep(amount, p);
    }

    function _close(CreditLine line) internal {
        IdentityRegistry.Proof memory p = _lineProof(line, keccak256("close"));
        address b = line.borrower();
        vm.prank(b);
        line.close(p);
    }

    function _openLine(address borrower, uint256 deposit, uint256 principal) internal returns (CreditLine line) {
        _registerPasskey(borrower);
        _approve(borrower, uint128(principal));
        ausd.mint(borrower, deposit);
        vm.startPrank(borrower);
        ausd.approve(address(manager), deposit);
        line = CreditLine(manager.openLine(deposit, principal));
        vm.stopPrank();
    }

    function _order(uint8 orderType, uint256 price, uint256 lot, uint256 leverageHdths)
        internal
        pure
        returns (IExchange.OrderDesc[] memory orders)
    {
        orders = new IExchange.OrderDesc[](1);
        orders[0].perpId = BTC;
        orders[0].orderType = IExchange.OrderDescEnum.wrap(orderType);
        orders[0].pricePNS = price;
        orders[0].lotLNS = lot;
        orders[0].immediateOrCancel = true;
        orders[0].maxMatches = 10;
        orders[0].leverageHdths = leverageHdths;
        orders[0].maxNegPnlCollatBPS = 1_000;
    }

    /// @dev Buy `lot` at the top of the 0.5% band (fills at mark + 5 bps in the mock).
    function _long(CreditLine line, uint256 lot, uint256 lev) internal {
        // Build the order before pranking: any external call in the arguments would consume the prank.
        IExchange.OrderDesc[] memory o = _order(0, (ex.mark(BTC) * 10_040) / 10_000, lot, lev);
        address borrower = line.borrower();
        vm.prank(borrower);
        line.trade(o);
    }

    function _closeLong(CreditLine line, uint256 lot) internal {
        IExchange.OrderDesc[] memory o = _order(2, (ex.mark(BTC) * 9_960) / 10_000, lot, 100);
        address borrower = line.borrower();
        vm.prank(borrower);
        line.trade(o);
    }
}
