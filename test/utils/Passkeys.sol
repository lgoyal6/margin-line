// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";

/// @notice Builds WebAuthn assertions byte-for-byte like a browser authenticator: authenticatorData
///         = rpIdHash | flags | signCount, clientDataJSON with the base64url challenge, and a P-256
///         signature over sha256(authenticatorData || sha256(clientDataJSON)).
abstract contract Passkeys is Test {
    bytes32 internal constant RP_ID_HASH = sha256("marginline.xyz");
    uint256 internal constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    bytes1 internal constant UP_UV = 0x05; // user present + user verified

    function _pubkey(uint256 pk) internal pure returns (bytes32 qx, bytes32 qy) {
        (uint256 x, uint256 y) = vm.publicKeyP256(pk);
        return (bytes32(x), bytes32(y));
    }

    function _assertion(uint256 pk, bytes32 challenge, bytes32 rpIdHash, bytes1 flags)
        internal
        pure
        returns (WebAuthn.WebAuthnAuth memory auth)
    {
        auth.authenticatorData = abi.encodePacked(rpIdHash, flags, uint32(1));
        string memory prefix = '{"type":"webauthn.get","challenge":"';
        auth.clientDataJSON = string.concat(
            prefix, Base64.encodeURL(abi.encodePacked(challenge)), '","origin":"https://marginline.xyz","crossOrigin":false}'
        );
        auth.typeIndex = 1;
        auth.challengeIndex = 23;
        bytes32 digest = sha256(abi.encodePacked(auth.authenticatorData, sha256(bytes(auth.clientDataJSON))));
        (bytes32 r, bytes32 s) = vm.signP256(pk, digest);
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s)); // low-s form
        auth.r = r;
        auth.s = s;
    }

    /// @notice A valid approval of `action` by `user`'s passkey `pk`, for `consumer`, at the current nonce.
    function _proof(IdentityRegistry reg, uint256 pk, address user, address consumer, bytes32 action)
        internal
        view
        returns (IdentityRegistry.Proof memory p)
    {
        (bytes32 qx, bytes32 qy) = _pubkey(pk);
        p.keyId = reg.keyIdOf(qx, qy);
        p.auth = _assertion(pk, reg.challengeFor(user, consumer, action), RP_ID_HASH, UP_UV);
    }
}
