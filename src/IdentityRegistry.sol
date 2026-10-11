// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";

/// @title IdentityRegistry
/// @notice Passkeys (WebAuthn, P-256) registered per user, used as a fresh second factor for actions
///         that move money out: profit sweeps, closing a line, granting session keys.
/// @dev Why a second factor when the user's wallet already comes from a passkey (Mera)? Mera keeps the
///      derived wallet key in page memory for the session, so any script on the page could sign with
///      it. A WebAuthn assertion requires a fresh biometric at the moment of the action, and it is
///      verified onchain through Monad's P-256 precompile at 0x100 (EIP-7951, via OpenZeppelin P256).
///
///      Every approval is bound to: this chain, this registry, the consuming contract, the user's nonce,
///      and a hash of the exact action. So an assertion cannot be replayed, used on another line, or
///      burned by a third party submitting it first. On top of OpenZeppelin's checks (type, challenge,
///      user presence and verification, signature) the registry also checks the rpIdHash, binding
///      assertions to the Margin Line web domain.
///
///      Keys live under an epoch per user. Guardian recovery bumps the epoch after a delay, which
///      retires every old key at once.
contract IdentityRegistry {
    struct Passkey {
        bytes32 qx;
        bytes32 qy;
    }

    struct Recovery {
        Passkey key;
        uint64 executeAfter;
    }

    /// @notice A user's approval for one action, produced by `navigator.credentials.get`.
    struct Proof {
        bytes32 keyId;
        WebAuthn.WebAuthnAuth auth;
    }

    bytes32 public constant APPROVE_TYPEHASH = keccak256("MarginLine.Approve(address user,address consumer,uint256 nonce,bytes32 action)");
    uint256 public constant MAX_KEYS = 8;
    uint256 public constant RECOVERY_DELAY = 3 days;

    /// @notice sha256 of the relying-party id (the web domain the passkeys are created for).
    bytes32 public immutable rpIdHash;

    mapping(address user => uint64) public epoch;
    mapping(address user => uint256) public nonce;
    mapping(address user => uint256) internal _keyCount;
    mapping(address user => mapping(uint64 epoch => mapping(bytes32 keyId => Passkey))) internal _keys;
    mapping(address user => address) public guardian;
    mapping(address user => Recovery) public pendingRecovery;

    error AlreadyRegistered();
    error NoPasskey();
    error UnknownKey(bytes32 keyId);
    error KeyExists(bytes32 keyId);
    error TooManyKeys();
    error LastKey();
    error InvalidAssertion();
    error WrongRelyingParty();
    error OnlyGuardian();
    error NoRecovery();
    error RecoveryNotReady(uint64 executeAfter);
    error InvalidKey();

    event PasskeyAdded(address indexed user, uint64 indexed epoch, bytes32 indexed keyId);
    event PasskeyRemoved(address indexed user, uint64 indexed epoch, bytes32 indexed keyId);
    event GuardianSet(address indexed user, address guardian);
    event RecoveryStarted(address indexed user, address indexed guardian, bytes32 keyId, uint64 executeAfter);
    event RecoveryCancelled(address indexed user);
    event RecoveryCompleted(address indexed user, uint64 newEpoch, bytes32 keyId);
    event Approved(address indexed user, address indexed consumer, uint256 nonce, bytes32 action);

    constructor(bytes32 rpIdHash_) {
        rpIdHash = rpIdHash_;
    }

    // ------------------------------------------------------------ keys

    /// @notice A user's first passkey, registered by the user's own wallet.
    function registerFirstPasskey(bytes32 qx, bytes32 qy) external returns (bytes32 keyId) {
        if (_keyCount[msg.sender] != 0) revert AlreadyRegistered();
        keyId = _add(msg.sender, qx, qy);
    }

    /// @notice Add another device's passkey, approved by an existing passkey.
    function addPasskey(bytes32 qx, bytes32 qy, Proof calldata proof) external returns (bytes32 keyId) {
        _consume(msg.sender, address(this), keccak256(abi.encode("addPasskey", qx, qy)), proof);
        keyId = _add(msg.sender, qx, qy);
    }

    /// @notice Remove a device's passkey, approved by a passkey. The last key cannot be removed here;
    ///         losing every device is what guardian recovery is for.
    function removePasskey(bytes32 keyId, Proof calldata proof) external {
        _consume(msg.sender, address(this), keccak256(abi.encode("removePasskey", keyId)), proof);
        uint64 e = epoch[msg.sender];
        if (_keys[msg.sender][e][keyId].qx == bytes32(0)) revert UnknownKey(keyId);
        if (_keyCount[msg.sender] == 1) revert LastKey();
        delete _keys[msg.sender][e][keyId];
        _keyCount[msg.sender]--;
        emit PasskeyRemoved(msg.sender, e, keyId);
    }

    function setGuardian(address guardian_, Proof calldata proof) external {
        _consume(msg.sender, address(this), keccak256(abi.encode("setGuardian", guardian_)), proof);
        guardian[msg.sender] = guardian_;
        emit GuardianSet(msg.sender, guardian_);
    }

    // ------------------------------------------------------------ recovery

    /// @notice The user's guardian proposes a replacement passkey. It takes effect after a delay,
    ///         during which the user can cancel with any current passkey.
    function startRecovery(address user, bytes32 qx, bytes32 qy) external {
        if (msg.sender != guardian[user] || msg.sender == address(0)) revert OnlyGuardian();
        if (qx == bytes32(0) || qy == bytes32(0)) revert InvalidKey();
        uint64 executeAfter = uint64(block.timestamp + RECOVERY_DELAY);
        pendingRecovery[user] = Recovery(Passkey(qx, qy), executeAfter);
        emit RecoveryStarted(user, msg.sender, _keyId(qx, qy), executeAfter);
    }

    function cancelRecovery(Proof calldata proof) external {
        _consume(msg.sender, address(this), keccak256("cancelRecovery"), proof);
        if (pendingRecovery[msg.sender].executeAfter == 0) revert NoRecovery();
        delete pendingRecovery[msg.sender];
        emit RecoveryCancelled(msg.sender);
    }

    /// @notice After the delay anyone can finalize: every old key is retired by moving to a new epoch.
    function completeRecovery(address user) external {
        Recovery memory r = pendingRecovery[user];
        if (r.executeAfter == 0) revert NoRecovery();
        if (block.timestamp < r.executeAfter) revert RecoveryNotReady(r.executeAfter);
        delete pendingRecovery[user];
        uint64 e = ++epoch[user];
        _keyCount[user] = 0;
        bytes32 keyId = _add(user, r.key.qx, r.key.qy);
        emit RecoveryCompleted(user, e, keyId);
    }

    // ------------------------------------------------------------ approvals

    /// @notice Consume one approval from `user` for `action`, on behalf of the calling contract.
    ///         Reverts unless the assertion is valid; succeeds at most once per nonce.
    function approve(address user, bytes32 action, Proof calldata proof) external {
        _consume(user, msg.sender, action, proof);
    }

    /// @notice The exact bytes the user's passkey must sign (as the WebAuthn challenge) to approve
    ///         `action` for `consumer` at the current nonce.
    function challengeFor(address user, address consumer, bytes32 action) public view returns (bytes32) {
        return keccak256(abi.encode(APPROVE_TYPEHASH, block.chainid, address(this), user, consumer, nonce[user], action));
    }

    function hasPasskey(address user) external view returns (bool) {
        return _keyCount[user] != 0;
    }

    function keyCount(address user) external view returns (uint256) {
        return _keyCount[user];
    }

    function passkey(address user, bytes32 keyId) external view returns (bytes32 qx, bytes32 qy) {
        Passkey memory k = _keys[user][epoch[user]][keyId];
        return (k.qx, k.qy);
    }

    function keyIdOf(bytes32 qx, bytes32 qy) external pure returns (bytes32) {
        return _keyId(qx, qy);
    }

    // ------------------------------------------------------------ internals

    function _consume(address user, address consumer, bytes32 action, Proof calldata proof) internal {
        if (_keyCount[user] == 0) revert NoPasskey();
        Passkey memory k = _keys[user][epoch[user]][proof.keyId];
        if (k.qx == bytes32(0)) revert UnknownKey(proof.keyId);
        if (proof.auth.authenticatorData.length < 37 || bytes32(proof.auth.authenticatorData[0:32]) != rpIdHash) {
            revert WrongRelyingParty();
        }
        bytes32 challenge = challengeFor(user, consumer, action);
        if (!WebAuthn.verify(abi.encodePacked(challenge), proof.auth, k.qx, k.qy, true)) revert InvalidAssertion();
        emit Approved(user, consumer, nonce[user]++, action);
    }

    function _add(address user, bytes32 qx, bytes32 qy) internal returns (bytes32 keyId) {
        if (qx == bytes32(0) || qy == bytes32(0)) revert InvalidKey();
        if (_keyCount[user] >= MAX_KEYS) revert TooManyKeys();
        uint64 e = epoch[user];
        keyId = _keyId(qx, qy);
        if (_keys[user][e][keyId].qx != bytes32(0)) revert KeyExists(keyId);
        _keys[user][e][keyId] = Passkey(qx, qy);
        _keyCount[user]++;
        emit PasskeyAdded(user, e, keyId);
    }

    function _keyId(bytes32 qx, bytes32 qy) internal pure returns (bytes32) {
        return keccak256(abi.encode(qx, qy));
    }
}
