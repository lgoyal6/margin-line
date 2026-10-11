// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ScoreOracle, IGuardianSource} from "../../src/ScoreOracle.sol";
import {ScoreRules} from "../../src/ScoreRules.sol";
import {MockGuardianSource, GasHungryReceiver} from "../mocks/MockGuardianSource.sol";

/// @notice ScoreOracle: who may propose, how roots are challenged and finalized, and that every bond
///         always ends up claimable by exactly one party.
contract ScoreOracleTest is Test {
    using ScoreRules for ScoreRules.Features;

    ScoreOracle oracle;
    MockGuardianSource source;
    address curator = makeAddr("curator");
    address publisher = makeAddr("publisher");
    address challenger = makeAddr("challenger");
    address challenger2 = makeAddr("challenger2");
    address guardian = makeAddr("guardian");
    uint256 constant PUB_BOND = 1 ether;
    uint256 constant CH_BOND = 0.5 ether;

    function setUp() public {
        source = new MockGuardianSource(guardian);
        oracle = new ScoreOracle(curator, IGuardianSource(address(source)), publisher, PUB_BOND, CH_BOND);
        vm.deal(publisher, 10 ether);
        vm.deal(challenger, 10 ether);
        vm.deal(challenger2, 10 ether);
        vm.roll(100);
    }

    function _f() internal pure returns (ScoreRules.Features memory) {
        return ScoreRules.Features({
            activeDays: 5, closes: 12, pnlExtMicro: 100e6, avgLevBps: 20_000, liqHist: 0,
            washShareBps: 0, washPair: false, maxDepositMicro: 1_000e6
        });
    }

    /// @dev Two-leaf tree: account 42 with `limit42`, account 43 consistent. Returns root and the
    ///      proof for account 42.
    function _tree(uint256 epoch, uint256 limit42) internal view returns (bytes32 root, bytes32[] memory proof42) {
        ScoreRules.Features memory f = _f();
        bytes32 a = oracle.leafHash(epoch, 42, f, limit42, f.aprFor());
        bytes32 b = oracle.leafHash(epoch, 43, f, f.limitFor(), f.aprFor());
        root = a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
        proof42 = new bytes32[](1);
        proof42[0] = b;
    }

    function _propose(uint256 epoch, bytes32 root) internal {
        vm.prank(publisher);
        oracle.propose{value: PUB_BOND}(epoch, root, block.number - 1, "ipfs://epoch");
    }

    /// Every wei the oracle holds is owed to someone: open bonds plus claimable balances.
    function _assertSolvent(address[] memory parties, uint256 openBonds) internal view {
        uint256 owed = openBonds;
        for (uint256 i; i < parties.length; ++i) owed += oracle.claimable(parties[i]);
        assertEq(address(oracle).balance, owed, "oracle balance != bonds owed");
    }

    function _parties() internal view returns (address[] memory p) {
        p = new address[](3);
        p[0] = publisher;
        p[1] = challenger;
        p[2] = challenger2;
    }

    // ------------------------------------------------------------ proposing

    function test_onlyPublisherProposes() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        vm.deal(challenger, 10 ether);
        vm.prank(challenger);
        vm.expectRevert(ScoreOracle.NotPublisher.selector);
        oracle.propose{value: PUB_BOND}(1, root, block.number - 1, "fake");
    }

    function test_proposalNeedsMinimumBond() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.BondTooSmall.selector, PUB_BOND - 1, PUB_BOND));
        oracle.propose{value: PUB_BOND - 1}(1, root, block.number - 1, "x");
    }

    function test_epochNumbersOnlyIncrease() public {
        (bytes32 root,) = _tree(5, _f().limitFor());
        _propose(5, root);
        vm.prank(publisher);
        vm.expectRevert(ScoreOracle.InvalidEpoch.selector);
        oracle.propose{value: PUB_BOND}(5, root, block.number - 1, "again");
        vm.prank(publisher);
        vm.expectRevert(ScoreOracle.InvalidEpoch.selector);
        oracle.propose{value: PUB_BOND}(4, root, block.number - 1, "older");
    }

    // ------------------------------------------------------------ finalizing

    function test_unchallengedRootFinalizesAndBondIsClaimable() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        _propose(1, root);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.NotFinalizable.selector, 1));
        oracle.finalize(1); // window still open
        vm.warp(block.timestamp + 1 days);
        oracle.finalize(1);
        assertTrue(oracle.isFinalized(1));
        assertEq(oracle.latestFinalizedEpoch(), 1);
        assertEq(oracle.claimable(publisher), PUB_BOND);
        uint256 before = publisher.balance;
        vm.prank(publisher);
        oracle.claim();
        assertEq(publisher.balance, before + PUB_BOND);
        _assertSolvent(_parties(), 0);
    }

    /// Regression: freshness used to overflow (revert) for every finalized epoch.
    function test_freshnessWorksAfterFinalizeAndExpires() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        _propose(1, root);
        assertFalse(oracle.epochIsFresh(1), "not fresh before finalization");
        vm.warp(block.timestamp + 1 days);
        oracle.finalize(1);
        assertTrue(oracle.epochIsFresh(1));
        vm.warp(block.timestamp + 29 days);
        assertTrue(oracle.epochIsFresh(1));
        vm.warp(block.timestamp + 1);
        assertFalse(oracle.epochIsFresh(1), "expires 30 days after proposal");
    }

    function test_cannotChallengeOrRefinalizeAfterFinalization() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        _propose(1, root);
        vm.warp(block.timestamp + 1 days);
        oracle.finalize(1);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.NotFinalizable.selector, 1));
        oracle.finalize(1);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.NotOpen.selector, 1));
        oracle.openArbitratedChallenge{value: CH_BOND}(1);
    }

    // ------------------------------------------------------------ trustless challenge

    function test_inconsistentLeafRejectsRootTrustlessly() public {
        (bytes32 root, bytes32[] memory proof) = _tree(1, 1); // account 42's limit should be 2,000
        _propose(1, root);
        ScoreRules.Features memory f = _f();
        vm.prank(challenger);
        oracle.challengeLeaf(1, 42, f, 1, f.aprFor(), proof);
        assertTrue(oracle.epochs(1).rejected);
        assertEq(oracle.claimable(challenger), PUB_BOND, "challenger takes the publisher's bond");
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.NotFinalizable.selector, 1));
        oracle.finalize(1); // a rejected root never finalizes
        _assertSolvent(_parties(), 0);
    }

    function test_consistentLeafCannotBeChallenged() public {
        (bytes32 root, bytes32[] memory proof) = _tree(1, _f().limitFor());
        _propose(1, root);
        ScoreRules.Features memory f = _f();
        vm.prank(challenger);
        vm.expectRevert(ScoreOracle.ConsistentLeaf.selector);
        oracle.challengeLeaf(1, 42, f, f.limitFor(), f.aprFor(), proof);
    }

    function test_leafNotInRootCannotChallenge() public {
        (bytes32 root, bytes32[] memory proof) = _tree(1, _f().limitFor());
        _propose(1, root);
        ScoreRules.Features memory f = _f();
        vm.prank(challenger);
        vm.expectRevert(ScoreOracle.InvalidProof.selector);
        oracle.challengeLeaf(1, 42, f, 1, f.aprFor(), proof); // claims a bad leaf the root never had
    }

    // ------------------------------------------------------------ arbitrated challenge

    /// Regression: arbitrated disputes used to be free, so anyone could block finalization forever.
    function test_arbitratedChallengeNeedsBond() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        _propose(1, root);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.BondTooSmall.selector, 0, CH_BOND));
        oracle.openArbitratedChallenge(1);
    }

    function test_disputeBlocksFinalizationUntilGuardianRulesValid() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        _propose(1, root);
        vm.prank(challenger);
        uint256 id = oracle.openArbitratedChallenge{value: CH_BOND}(1);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.NotFinalizable.selector, 1));
        oracle.finalize(1);

        vm.prank(curator); // the owner is not the guardian
        vm.expectRevert(ScoreOracle.OnlyGuardian.selector);
        oracle.resolveArbitrated(id, true);
        vm.prank(guardian);
        oracle.resolveArbitrated(id, true);

        oracle.finalize(1);
        assertEq(oracle.claimable(publisher), PUB_BOND + CH_BOND, "a failed dispute pays the publisher");
        _assertSolvent(_parties(), 0);
    }

    function test_guardianRulingInvalidRejectsRootAndRefundsChallenger() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        _propose(1, root);
        vm.prank(challenger);
        uint256 id = oracle.openArbitratedChallenge{value: CH_BOND}(1);
        vm.prank(guardian);
        oracle.resolveArbitrated(id, false);
        assertTrue(oracle.epochs(1).rejected);
        assertEq(oracle.claimable(challenger), CH_BOND + PUB_BOND);
        _assertSolvent(_parties(), 0);
    }

    /// Regression: when a root was rejected, other open disputes on it kept their bonds forever.
    function test_otherDisputesReclaimBondsAfterRejection() public {
        (bytes32 root, bytes32[] memory proof) = _tree(1, 1);
        _propose(1, root);
        vm.prank(challenger2);
        uint256 id2 = oracle.openArbitratedChallenge{value: CH_BOND}(1);
        _assertSolvent(_parties(), PUB_BOND + CH_BOND);

        ScoreRules.Features memory f = _f();
        vm.prank(challenger);
        oracle.challengeLeaf(1, 42, f, 1, f.aprFor(), proof);

        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.NoChallenge.selector, 999));
        oracle.reclaimChallenge(999);
        oracle.reclaimChallenge(id2); // anyone may trigger; the bond goes to its challenger
        assertEq(oracle.claimable(challenger2), CH_BOND);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.NoChallenge.selector, id2));
        oracle.reclaimChallenge(id2);
        _assertSolvent(_parties(), 0);
    }

    function test_cannotReclaimWhileEpochStillLive() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        _propose(1, root);
        vm.prank(challenger);
        uint256 id = oracle.openArbitratedChallenge{value: CH_BOND}(1);
        vm.expectRevert(abi.encodeWithSelector(ScoreOracle.EpochNotRejected.selector, 1));
        oracle.reclaimChallenge(id);
    }

    /// The guardian is read live from the market's curator, so a guardian change takes effect at once.
    function test_guardianFollowsTheCurator() public {
        (bytes32 root,) = _tree(1, _f().limitFor());
        _propose(1, root);
        vm.prank(challenger);
        uint256 id = oracle.openArbitratedChallenge{value: CH_BOND}(1);
        address newGuardian = makeAddr("new-guardian");
        source.setGuardian(newGuardian);
        vm.prank(guardian);
        vm.expectRevert(ScoreOracle.OnlyGuardian.selector);
        oracle.resolveArbitrated(id, true);
        vm.prank(newGuardian);
        oracle.resolveArbitrated(id, true);
    }

    // ------------------------------------------------------------ payouts and domain separation

    /// Regression: `transfer` forwarded 2,300 gas, so contract wallets could not receive bonds.
    function test_contractWalletCanReceiveBond() public {
        GasHungryReceiver wallet = new GasHungryReceiver();
        vm.prank(curator);
        oracle.setPublisher(address(wallet));
        (bytes32 root,) = _tree(1, _f().limitFor());
        vm.deal(address(this), PUB_BOND);
        wallet.call{value: PUB_BOND}(
            address(oracle), abi.encodeCall(ScoreOracle.propose, (1, root, block.number - 1, "multisig"))
        );
        vm.warp(block.timestamp + 1 days);
        oracle.finalize(1);
        wallet.call(address(oracle), abi.encodeCall(ScoreOracle.claim, ()));
        assertEq(address(wallet).balance, PUB_BOND);
    }

    function test_leafIsBoundToChainAndOracle() public {
        ScoreOracle other = new ScoreOracle(curator, IGuardianSource(address(source)), publisher, PUB_BOND, CH_BOND);
        ScoreRules.Features memory f = _f();
        assertTrue(
            other.leafHash(1, 42, f, f.limitFor(), f.aprFor()) != oracle.leafHash(1, 42, f, f.limitFor(), f.aprFor())
        );
        bytes32 here = oracle.leafHash(1, 42, f, f.limitFor(), f.aprFor());
        vm.chainId(143);
        assertTrue(oracle.leafHash(1, 42, f, f.limitFor(), f.aprFor()) != here, "chain id is part of the leaf");
    }

    function test_onlyOwnerChangesSettings() public {
        vm.startPrank(publisher);
        vm.expectRevert();
        oracle.setPublisher(publisher);
        vm.expectRevert();
        oracle.setBonds(0, 0);
        vm.expectRevert();
        oracle.setChallengeWindow(1 hours);
        vm.stopPrank();
        vm.startPrank(curator);
        vm.expectRevert(ScoreOracle.InvalidSetting.selector);
        oracle.setChallengeWindow(1 hours - 1);
        vm.expectRevert(ScoreOracle.InvalidSetting.selector);
        oracle.setMaxEpochAge(1 days - 1);
        vm.stopPrank();
    }
}
