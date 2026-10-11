// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Passkeys} from "../utils/Passkeys.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccount} from "perpl-delegated-account/DelegatedAccount.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {TrancheVault} from "../../src/TrancheVault.sol";
import {CreditManager} from "../../src/CreditManager.sol";
import {CreditLine, ICreditManager} from "../../src/CreditLine.sol";
import {TradeGuard} from "../../src/TradeGuard.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";
import {CircuitBreaker} from "../../src/CircuitBreaker.sol";

/// @notice The full protocol against Perpl's real Exchange and DelegatedAccountFactory on a Monad
///         testnet fork: lend, open a line, trade on the real order book within the band, freeze and
///         unwind with a reduce-only order, settle. Runs on a local fork of Monad testnet or mainnet; no
///         real transactions.
contract CreditLineForkTest is Passkeys {
    IExchange EXCHANGE;
    DelegatedAccountFactory FACTORY;
    IERC20 AUSD;
    uint256 BTC;

    CreditPool pool;
    TrancheVault junior;
    TradeGuard guard;
    CreditManager manager;
    IdentityRegistry identity;
    uint256 constant ALICE_PASSKEY = 0xA11CE;
    address admin = makeAddr("admin");
    address underwriter = makeAddr("underwriter");
    address lender = makeAddr("lender");
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        if (block.chainid == 10143) {
            EXCHANGE = IExchange(0x1964C32f0bE608E7D29302AFF5E61268E72080cc);
            FACTORY = DelegatedAccountFactory(0xf42548Ccb3300Bc76c35dc2D347416db2E8d7209);
            AUSD = IERC20(0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC);
            BTC = 16;
        } else if (block.chainid == 143) {
            EXCHANGE = IExchange(0x34B6552d57a35a1D042CcAe1951BD1C370112a6F);
            FACTORY = DelegatedAccountFactory(0xc535276e3e446e4F28D95ed27cCd5c32e4C8907a);
            AUSD = IERC20(0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a);
            BTC = 1;
        } else {
            revert("run with --fork-url pointing at Monad testnet or mainnet");
        }
        identity = new IdentityRegistry(RP_ID_HASH);
        pool = new CreditPool(AUSD, admin);
        TrancheVault senior = new TrancheVault(pool, CreditPool.Tranche.Senior, "Margin Line Senior", "mlSR");
        junior = new TrancheVault(pool, CreditPool.Tranche.Junior, "Margin Line Junior", "mlJR");
        guard = new TradeGuard(admin, 600);
        manager = new CreditManager(pool, EXCHANGE, identity, admin);
        CreditLine impl = new CreditLine(address(manager), pool, guard, EXCHANGE, FACTORY, AUSD, identity);
        (bytes32 qx, bytes32 qy) = _pubkey(ALICE_PASSKEY);
        vm.prank(alice);
        identity.registerFirstPasskey(qx, qy);
        CircuitBreaker breaker = new CircuitBreaker(admin);
        vm.startPrank(admin);
        breaker.setMinInsuranceBps(10); // trips if insurance < 0.1% of one side's OI notional
        manager.setBreaker(breaker);
        pool.wire(address(manager), address(senior), address(junior));
        manager.setLineImplementation(address(impl));
        manager.setUnderwriter(underwriter);
        guard.setMarket(BTC, true, 300, 100); // 3x, 1% band (testnet books are thin)
        vm.stopPrank();

        _fund(lender, 10_000e6);
        vm.startPrank(lender);
        AUSD.approve(address(junior), 10_000e6);
        junior.deposit(10_000e6, lender);
        vm.stopPrank();
    }

    function test_fullLifecycleOnRealPerpl() public {
        CreditLine line = _open(200e6, 400e6);
        DelegatedAccount account = line.account();
        assertEq(account.owner(), address(line));
        assertFalse(account.isOperator(alice));
        assertEq(EXCHANGE.getAccountById(account.accountId()).balanceCNS, 600e6);

        // Long 0.003 BTC (about $250) at 2x through the guard, on Perpl's real book.
        IExchange.OrderDesc[] memory o = _orders(0, _ask() * 1_008 / 1_000, 300, 200);
        vm.prank(alice);
        line.trade(o);
        (IExchange.PositionInfoV2 memory pos,,) = EXCHANGE.getPositionV2(BTC, account.accountId());
        assertEq(pos.lotLNS, 300, "position opened");
        assertEq(IExchange.PositionEnum.unwrap(pos.positionType), 0, "Perpl encodes long as 0");
        assertGt(line.healthBps(), 14_000);

        // A colluding close 3% under mark is refused before it reaches Perpl.
        uint256 mark = EXCHANGE.getPerpetualInfoV2(BTC).markPNS;
        o = _orders(2, mark * 97 / 100, 300, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TradeGuard.PriceOutsideBand.selector, mark * 97 / 100, mark, uint16(100)));
        line.trade(o);

        // The borrower closes normally and settles the line; the lender is repaid.
        o = _orders(2, _bid() * 992 / 1_000, 300, 100);
        vm.prank(alice);
        line.trade(o);
        IdentityRegistry.Proof memory p = _proof(identity, ALICE_PASSKEY, alice, address(line), keccak256("close"));
        vm.prank(alice);
        line.close(p); // Face ID approval, verified onchain with P-256
        assertEq(pool.principalOf(address(line)), 0);
        assertEq(uint8(line.state()), uint8(CreditLine.State.Closed));
        assertGt(AUSD.balanceOf(alice), 190e6, "deposit returned minus fees");
    }

    function test_freezeAndUnwindOnRealPerpl() public {
        CreditLine line = _open(200e6, 400e6);
        IExchange.OrderDesc[] memory o = _orders(0, _ask() * 1_008 / 1_000, 300, 200);
        vm.prank(alice);
        line.trade(o);

        // Make the line unhealthy without moving Perpl's price: raise the freeze bar above its health.
        vm.prank(admin);
        manager.setRiskParams(
            ICreditManager.RiskParams({freezeHealthBps: 20_000, openHealthBps: 21_000, sweepHealthBps: 21_000}), 30_000
        );
        vm.startPrank(keeper);
        line.freeze();
        line.unwind(BTC, type(uint256).max); // reduce-only IOC at the band edge, on the real book
        vm.stopPrank();
        (IExchange.PositionInfoV2 memory pos,,) = EXCHANGE.getPositionV2(BTC, line.account().accountId());
        assertEq(pos.lotLNS, 0, "keeper unwound the position");

        vm.prank(keeper);
        line.settleFrozen();
        assertEq(pool.principalOf(address(line)), 0);
        assertEq(pool.totalLosses(), 0);
    }

    // ------------------------------------------------------------ helpers

    function _open(uint256 deposit, uint256 principal) internal returns (CreditLine line) {
        vm.prank(underwriter);
        manager.approve(alice, uint128(principal), 1_000, uint40(block.timestamp + 1 days));
        _fund(alice, deposit);
        vm.startPrank(alice);
        AUSD.approve(address(manager), deposit);
        line = CreditLine(manager.openLine(deposit, principal));
        vm.stopPrank();
    }

    /// @dev AUSD's storage layout defeats `deal`; on a fork, fund from the Exchange's own balance.
    function _fund(address to, uint256 amount) internal {
        vm.prank(address(EXCHANGE));
        AUSD.transfer(to, amount);
    }

    function _ask() internal view returns (uint256) {
        IExchange.PerpetualInfoV2 memory p = EXCHANGE.getPerpetualInfoV2(BTC);
        return p.minAskPriceONS + p.basePricePNS;
    }

    function _bid() internal view returns (uint256) {
        IExchange.PerpetualInfoV2 memory p = EXCHANGE.getPerpetualInfoV2(BTC);
        return p.maxBidPriceONS + p.basePricePNS;
    }

    function _orders(uint8 t, uint256 price, uint256 lot, uint256 lev)
        internal
        view
        returns (IExchange.OrderDesc[] memory o)
    {
        o = new IExchange.OrderDesc[](1);
        o[0].perpId = BTC;
        o[0].orderType = IExchange.OrderDescEnum.wrap(t);
        o[0].pricePNS = price;
        o[0].lotLNS = lot;
        o[0].immediateOrCancel = true;
        o[0].maxMatches = 50;
        o[0].leverageHdths = lev;
        o[0].maxNegPnlCollatBPS = 1_000;
    }
}
