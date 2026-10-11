// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fixture} from "../utils/Fixture.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {HistoryLinkRegistry} from "../../src/HistoryLinkRegistry.sol";
import {ScoreOracle, IGuardianSource} from "../../src/ScoreOracle.sol";
import {MockGuardianSource} from "../mocks/MockGuardianSource.sol";
import {ScoreRules} from "../../src/ScoreRules.sol";
import {CreditManager} from "../../src/CreditManager.sol";

contract ScoreManagerTest is Fixture {
    using ScoreRules for ScoreRules.Features;
    HistoryLinkRegistry links;
    ScoreOracle oracle;
    uint256 constant WALLET_KEY = 0xCAFE;

    function setUp() public override {
        super.setUp();
        links = new HistoryLinkRegistry(IExchange(address(ex)));
        oracle = _newOracle();
        vm.startPrank(admin);
        manager.setHistoryLinks(links);
        manager.setScoreOracle(oracle);
        oracle.setChallengeWindow(1 hours);
        vm.stopPrank();
    }

    function _newOracle() internal returns (ScoreOracle) {
        return new ScoreOracle(admin, IGuardianSource(address(new MockGuardianSource(admin))), admin, 0, 0);
    }

    function _features() internal pure returns (ScoreRules.Features memory) {
        return ScoreRules.Features({activeDays: 5, closes: 12, pnlExtMicro: 100e6, avgLevBps: 20_000,
            liqHist: 0, washShareBps: 0, washPair: false, maxDepositMicro: 1_000e6});
    }

    function _linkHistory() internal returns (uint256 id) {
        address wallet = vm.addr(WALLET_KEY);
        ausd.mint(wallet, 100e6);
        vm.prank(wallet);
        ausd.approve(address(ex), 100e6);
        vm.prank(wallet);
        id = ex.createAccount(100e6);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 hash = keccak256(abi.encode(links.LINK_TYPEHASH(), alice, id, links.nonces(wallet), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", links.domainSeparator(), hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WALLET_KEY, digest);
        vm.prank(alice);
        links.link(id, wallet, deadline, abi.encodePacked(r, s, v));
    }

    function _post(uint256 epoch, uint256 id, ScoreRules.Features memory f, uint256 limit, uint256 apr) internal {
        bytes32 leaf = oracle.leafHash(epoch, id, f, limit, apr);
        vm.roll(block.number + 2);
        vm.prank(admin);
        oracle.propose(epoch, leaf, block.number - 1, "fixture");
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.finalize(epoch);
    }

    function _open(uint256 epoch, uint256 id, ScoreRules.Features memory f, uint256 limit, uint256 apr)
        internal
        returns (address)
    {
        _registerPasskey(alice);
        ausd.mint(alice, 1_000e6);
        vm.startPrank(alice);
        ausd.approve(address(manager), 1_000e6);
        address line = manager.openLineWithScore(1_000e6, 1_000e6, epoch, id, f, limit, apr, new bytes32[](0));
        vm.stopPrank();
        return line;
    }

    function testOpensFromFinalizedLinkedLeaf() public {
        uint256 id = _linkHistory();
        ScoreRules.Features memory f = _features();
        _post(1, id, f, f.limitFor(), f.aprFor());
        assertTrue(_open(1, id, f, f.limitFor(), f.aprFor()) != address(0));
    }

    function testRejectsUnfinalizedRoot() public {
        uint256 id = _linkHistory();
        ScoreRules.Features memory f = _features();
        bytes32 leaf = oracle.leafHash(2, id, f, f.limitFor(), f.aprFor());
        vm.roll(block.number + 2);
        vm.prank(admin);
        oracle.propose(2, leaf, block.number - 1, "fixture");
        _registerPasskey(alice);
        vm.expectRevert(CreditManager.ScoreNotFinalized.selector);
        vm.prank(alice);
        manager.openLineWithScore(1_000e6, 1_000e6, 2, id, f, f.limitFor(), f.aprFor(), new bytes32[](0));
    }

    function testRejectsUnlinkedAccountAndOverLimit() public {
        ScoreRules.Features memory f = _features();
        _post(3, 99, f, f.limitFor(), f.aprFor());
        _registerPasskey(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.UnlinkedHistory.selector, 99));
        vm.prank(alice);
        manager.openLineWithScore(1_000e6, 1_000e6, 3, 99, f, f.limitFor(), f.aprFor(), new bytes32[](0));
    }

    function testRejectsOverLimitAndLeafFromAnotherOracle() public {
        uint256 id = _linkHistory();
        ScoreRules.Features memory f = _features();
        _post(6, id, f, f.limitFor(), f.aprFor());
        _registerPasskey(alice);
        vm.expectRevert(abi.encodeWithSelector(CreditManager.AboveLimit.selector, 2_001e6, f.limitFor()));
        vm.prank(alice);
        manager.openLineWithScore(1_000e6, 2_001e6, 6, id, f, f.limitFor(), f.aprFor(), new bytes32[](0));

        // Replay: a leaf built for another market's oracle, posted here, must not verify.
        ScoreOracle other = _newOracle();
        bytes32 foreignLeaf = other.leafHash(7, id, f, f.limitFor(), f.aprFor());
        vm.roll(block.number + 2);
        vm.prank(admin);
        oracle.propose(7, foreignLeaf, block.number - 1, "replayed");
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.finalize(7);
        vm.expectRevert(CreditManager.ScoreProofInvalid.selector);
        vm.prank(alice);
        manager.openLineWithScore(1_000e6, 1_000e6, 7, id, f, f.limitFor(), f.aprFor(), new bytes32[](0));
    }

    function testInconsistentLeafHasItsOwnError() public {
        uint256 id = _linkHistory();
        ScoreRules.Features memory f = _features();
        _post(8, id, f, 5_000e6, f.aprFor()); // limit 5,000 does not follow from these features
        _registerPasskey(alice);
        vm.expectRevert(CreditManager.ScoreLeafInconsistent.selector);
        vm.prank(alice);
        manager.openLineWithScore(1_000e6, 1_000e6, 8, id, f, 5_000e6, f.aprFor(), new bytes32[](0));
    }

    function testRejectsStaleEpoch() public {
        uint256 id = _linkHistory();
        ScoreRules.Features memory f = _features();
        _post(4, id, f, f.limitFor(), f.aprFor());
        vm.prank(admin);
        oracle.setMaxEpochAge(1 days);
        vm.warp(block.timestamp + 1 days + 1);
        _registerPasskey(alice);
        vm.expectRevert(CreditManager.ScoreExpired.selector);
        vm.prank(alice);
        manager.openLineWithScore(1_000e6, 1_000e6, 4, id, f, f.limitFor(), f.aprFor(), new bytes32[](0));
    }
}
