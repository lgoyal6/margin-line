// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ScoreRules} from "./ScoreRules.sol";

interface IGuardianSource {
    function guardian() external view returns (address);
}

/// @title ScoreOracle
/// @notice Publishes credit-score epochs as Merkle roots and lets anyone challenge them.
///
///         The publisher posts a root with a bond. During the challenge window:
///         - anyone can prove one leaf whose stated limit or APR does not follow from its own
///           features under `ScoreRules`; the contract checks this itself and rejects the root;
///         - anyone can post a bond to dispute a leaf's features against chain data; the market's
///           guardian decides, and the root cannot finalize while any dispute is open.
///         An unchallenged root finalizes after the window and stays usable for `maxEpochAge`.
/// @dev Bonds are credited to `claimable` and withdrawn by their owner (pull payments), so no payout
///      can be blocked by a recipient and no bond can be stranded. Leaves are domain-separated by
///      chain and oracle, so a proof for one market's oracle never verifies on another.
contract ScoreOracle is Ownable, ReentrancyGuardTransient {
    using ScoreRules for ScoreRules.Features;

    struct Epoch {
        bytes32 root;
        uint256 cutoffBlock;
        uint256 proposedAt;
        uint256 bond;
        address publisher;
        uint32 openChallenges;
        bool rejected;
        bool finalized;
        string dataURI;
    }

    struct Challenge {
        uint256 epoch;
        address challenger;
        uint256 bond;
        bool open;
    }

    /// @notice Source of the guardian who resolves disputes: the market's RiskCurator.
    IGuardianSource public immutable guardianSource;

    address public publisher;
    uint256 public minPublisherBond;
    uint256 public minChallengeBond;
    uint256 public challengeWindow = 1 days;
    uint256 public maxEpochAge = 30 days;

    uint256 public lastProposedEpoch;
    uint256 public latestFinalizedEpoch;
    uint256 public challengeCount;
    mapping(uint256 epoch => Epoch) internal _epochs;
    mapping(uint256 id => Challenge) public challenges;
    mapping(address => uint256) public claimable;

    error NotPublisher();
    error BondTooSmall(uint256 sent, uint256 min);
    error InvalidEpoch();
    error NotOpen(uint256 epoch);
    error NotFinalizable(uint256 epoch);
    error InvalidProof();
    error ConsistentLeaf();
    error NoChallenge(uint256 id);
    error OnlyGuardian();
    error EpochNotRejected(uint256 epoch);
    error InvalidSetting();
    error NothingToClaim();
    error PayoutFailed();

    event Proposed(uint256 indexed epoch, bytes32 indexed root, uint256 bond, uint256 cutoffBlock, string dataURI);
    event Challenged(uint256 indexed epoch, uint256 indexed id, address indexed challenger, uint256 bond);
    event Arbitrated(uint256 indexed epoch, uint256 indexed id, bool rootValid);
    event Rejected(uint256 indexed epoch, address indexed challenger, uint256 reward);
    event Finalized(uint256 indexed epoch, bytes32 indexed root);
    event Claimed(address indexed to, uint256 amount);
    event ChallengeReclaimed(uint256 indexed epoch, uint256 indexed id, address indexed challenger, uint256 bond);
    event PublisherSet(address publisher);
    event BondsSet(uint256 minPublisherBond, uint256 minChallengeBond);
    event ChallengeWindowSet(uint256 challengeWindow);
    event MaxEpochAgeSet(uint256 maxEpochAge);

    constructor(
        address owner_,
        IGuardianSource guardianSource_,
        address publisher_,
        uint256 minPublisherBond_,
        uint256 minChallengeBond_
    ) Ownable(owner_) {
        guardianSource = guardianSource_;
        publisher = publisher_;
        minPublisherBond = minPublisherBond_;
        minChallengeBond = minChallengeBond_;
    }

    // ------------------------------------------------------------ views

    function epochs(uint256 epoch) external view returns (Epoch memory) {
        return _epochs[epoch];
    }

    function rootFor(uint256 epoch) external view returns (bytes32) {
        return _epochs[epoch].root;
    }

    function isFinalized(uint256 epoch) public view returns (bool) {
        return _epochs[epoch].finalized;
    }

    /// @notice Finalized and its data no older than `maxEpochAge` (measured from proposal).
    function epochIsFresh(uint256 epoch) external view returns (bool) {
        Epoch storage e = _epochs[epoch];
        return e.finalized && block.timestamp <= e.proposedAt + maxEpochAge;
    }

    function guardian() public view returns (address) {
        return guardianSource.guardian();
    }

    /// @notice The leaf for one scored Perpl account. The only leaf encoding: the publisher, the
    ///         challenge path and CreditManager all use it.
    function leafHash(
        uint256 epoch,
        uint256 perplAccount,
        ScoreRules.Features calldata f,
        uint256 limit,
        uint256 aprBps
    ) public view returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(block.chainid, address(this), epoch, perplAccount, f, limit, aprBps)))
        );
    }

    function verifyLeaf(
        uint256 epoch,
        uint256 perplAccount,
        ScoreRules.Features calldata f,
        uint256 limit,
        uint256 aprBps,
        bytes32[] calldata proof
    ) public view returns (bool) {
        return MerkleProof.verify(proof, _epochs[epoch].root, leafHash(epoch, perplAccount, f, limit, aprBps));
    }

    // ------------------------------------------------------------ publisher

    /// @notice Propose the next epoch. Epoch numbers only increase; a rejected number is not reused.
    ///         `cutoffBlock` is the last block of Perpl history included, on the history's own chain.
    function propose(uint256 epoch, bytes32 root, uint256 cutoffBlock, string calldata dataURI) external payable {
        if (msg.sender != publisher) revert NotPublisher();
        if (msg.value < minPublisherBond) revert BondTooSmall(msg.value, minPublisherBond);
        // `cutoffBlock` is on the chain the history comes from (Perpl on Monad mainnet), which need not
        // be this chain, so it is recorded for verification rather than compared with block.number.
        if (epoch <= lastProposedEpoch || root == bytes32(0) || cutoffBlock == 0) revert InvalidEpoch();
        lastProposedEpoch = epoch;
        _epochs[epoch] = Epoch(root, cutoffBlock, block.timestamp, msg.value, msg.sender, 0, false, false, dataURI);
        emit Proposed(epoch, root, msg.value, cutoffBlock, dataURI);
    }

    /// @notice Anyone may finalize an unchallenged root after the window; the publisher's bond
    ///         becomes claimable.
    function finalize(uint256 epoch) external {
        Epoch storage e = _epochs[epoch];
        if (
            e.root == bytes32(0) || e.rejected || e.finalized || e.openChallenges != 0
                || block.timestamp < e.proposedAt + challengeWindow
        ) revert NotFinalizable(epoch);
        e.finalized = true;
        if (epoch > latestFinalizedEpoch) latestFinalizedEpoch = epoch;
        _credit(e.publisher, e.bond);
        e.bond = 0;
        emit Finalized(epoch, e.root);
    }

    // ------------------------------------------------------------ challenges

    /// @notice Trustless: prove a leaf whose limit or APR does not follow from its own features.
    ///         Rejects the root at once and awards the publisher's bond to the challenger.
    function challengeLeaf(
        uint256 epoch,
        uint256 perplAccount,
        ScoreRules.Features calldata f,
        uint256 statedLimit,
        uint256 statedApr,
        bytes32[] calldata proof
    ) external {
        _requireOpen(epoch);
        if (!verifyLeaf(epoch, perplAccount, f, statedLimit, statedApr, proof)) revert InvalidProof();
        if (statedLimit == f.limitFor() && statedApr == f.aprFor()) revert ConsistentLeaf();
        _reject(epoch, msg.sender);
    }

    /// @notice Dispute a leaf's features against chain data. Bonded; blocks finalization until the
    ///         guardian resolves it. Evidence goes offchain, referenced by the event.
    function openArbitratedChallenge(uint256 epoch) external payable returns (uint256 id) {
        _requireOpen(epoch);
        if (msg.value < minChallengeBond) revert BondTooSmall(msg.value, minChallengeBond);
        id = ++challengeCount;
        challenges[id] = Challenge(epoch, msg.sender, msg.value, true);
        _epochs[epoch].openChallenges++;
        emit Challenged(epoch, id, msg.sender, msg.value);
    }

    /// @notice The guardian's ruling. Valid root: the challenger's bond goes to the publisher.
    ///         Invalid root: the root is rejected and the challenger gets both bonds back.
    function resolveArbitrated(uint256 id, bool rootValid) external {
        if (msg.sender != guardian()) revert OnlyGuardian();
        Challenge storage c = challenges[id];
        if (!c.open) revert NoChallenge(id);
        Epoch storage e = _epochs[c.epoch];
        c.open = false;
        e.openChallenges--;
        uint256 bond = c.bond;
        c.bond = 0;
        if (rootValid) {
            _credit(e.publisher, bond);
        } else {
            _credit(c.challenger, bond);
            _reject(c.epoch, c.challenger);
        }
        emit Arbitrated(c.epoch, id, rootValid);
    }

    /// @notice After a root is rejected, any other dispute on it is moot: its challenger takes the
    ///         bond back.
    function reclaimChallenge(uint256 id) external {
        Challenge storage c = challenges[id];
        if (!c.open) revert NoChallenge(id);
        if (!_epochs[c.epoch].rejected) revert EpochNotRejected(c.epoch);
        c.open = false;
        uint256 bond = c.bond;
        c.bond = 0;
        _credit(c.challenger, bond);
        emit ChallengeReclaimed(c.epoch, id, c.challenger, bond);
    }

    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert PayoutFailed();
        emit Claimed(msg.sender, amount);
    }

    // ------------------------------------------------------------ owner (the market's RiskCurator, timelocked)

    function setPublisher(address publisher_) external onlyOwner {
        publisher = publisher_;
        emit PublisherSet(publisher_);
    }

    function setBonds(uint256 minPublisherBond_, uint256 minChallengeBond_) external onlyOwner {
        minPublisherBond = minPublisherBond_;
        minChallengeBond = minChallengeBond_;
        emit BondsSet(minPublisherBond_, minChallengeBond_);
    }

    function setChallengeWindow(uint256 value) external onlyOwner {
        if (value < 1 hours || value > 30 days) revert InvalidSetting();
        challengeWindow = value;
        emit ChallengeWindowSet(value);
    }

    function setMaxEpochAge(uint256 value) external onlyOwner {
        if (value < 1 days || value > 365 days) revert InvalidSetting();
        maxEpochAge = value;
        emit MaxEpochAgeSet(value);
    }

    // ------------------------------------------------------------ internals

    function _requireOpen(uint256 epoch) internal view {
        Epoch storage e = _epochs[epoch];
        if (e.root == bytes32(0) || e.rejected || e.finalized) revert NotOpen(epoch);
    }

    /// @dev Rejection awards the publisher's bond to `challenger`. Other open disputes on the epoch
    ///      are released through `reclaimChallenge`; the open count no longer matters once rejected.
    function _reject(uint256 epoch, address challenger) internal {
        Epoch storage e = _epochs[epoch];
        e.rejected = true;
        uint256 reward = e.bond;
        e.bond = 0;
        _credit(challenger, reward);
        emit Rejected(epoch, challenger, reward);
    }

    function _credit(address to, uint256 amount) internal {
        if (amount != 0) claimable[to] += amount;
    }
}
