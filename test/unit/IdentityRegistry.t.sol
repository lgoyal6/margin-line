// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";
import {Passkeys} from "../utils/Passkeys.sol";

contract IdentityRegistryTest is Passkeys {
    IdentityRegistry reg;
    address user = makeAddr("user");
    address guardianAddr = makeAddr("guardian");
    address consumer = makeAddr("consumer"); // stands in for a CreditLine
    uint256 constant PHONE = 0xA11CE;
    uint256 constant LAPTOP = 0xB0B;
    uint256 constant NEW_PHONE = 0xC0FFEE;
    bytes32 constant ACTION = keccak256("sweep 100");

    function setUp() public {
        reg = new IdentityRegistry(RP_ID_HASH);
        (bytes32 qx, bytes32 qy) = _pubkey(PHONE);
        vm.prank(user);
        reg.registerFirstPasskey(qx, qy);
    }

    function test_validApprovalIsAcceptedOnceThenNonceMoves() public {
        IdentityRegistry.Proof memory p = _proof(reg, PHONE, user, consumer, ACTION);
        vm.prank(consumer);
        reg.approve(user, ACTION, p);
        assertEq(reg.nonce(user), 1);
        vm.prank(consumer);
        vm.expectRevert(IdentityRegistry.InvalidAssertion.selector); // replay: challenge now differs
        reg.approve(user, ACTION, p);
    }

    function test_approvalIsBoundToTheConsumer() public {
        IdentityRegistry.Proof memory p = _proof(reg, PHONE, user, consumer, ACTION);
        vm.prank(makeAddr("front-runner"));
        vm.expectRevert(IdentityRegistry.InvalidAssertion.selector);
        reg.approve(user, ACTION, p);
    }

    function test_approvalIsBoundToTheAction() public {
        IdentityRegistry.Proof memory p = _proof(reg, PHONE, user, consumer, ACTION);
        vm.prank(consumer);
        vm.expectRevert(IdentityRegistry.InvalidAssertion.selector);
        reg.approve(user, keccak256("sweep 1000000"), p);
    }

    function test_unregisteredKeyRejected() public {
        IdentityRegistry.Proof memory p = _proof(reg, LAPTOP, user, consumer, ACTION);
        vm.prank(consumer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UnknownKey.selector, p.keyId));
        reg.approve(user, ACTION, p);
    }

    function test_signatureFromAnotherKeyRejected() public {
        IdentityRegistry.Proof memory p = _proof(reg, LAPTOP, user, consumer, ACTION);
        (bytes32 qx, bytes32 qy) = _pubkey(PHONE);
        p.keyId = reg.keyIdOf(qx, qy); // claim to be the phone, signed by the laptop
        vm.prank(consumer);
        vm.expectRevert(IdentityRegistry.InvalidAssertion.selector);
        reg.approve(user, ACTION, p);
    }

    function test_wrongWebsiteRejected() public {
        IdentityRegistry.Proof memory p = _proof(reg, PHONE, user, consumer, ACTION);
        p.auth = _assertion(PHONE, reg.challengeFor(user, consumer, ACTION), sha256("evil.example"), UP_UV);
        vm.prank(consumer);
        vm.expectRevert(IdentityRegistry.WrongRelyingParty.selector);
        reg.approve(user, ACTION, p);
    }

    function test_userVerificationRequired() public {
        IdentityRegistry.Proof memory p = _proof(reg, PHONE, user, consumer, ACTION);
        p.auth = _assertion(PHONE, reg.challengeFor(user, consumer, ACTION), RP_ID_HASH, 0x01); // presence only
        vm.prank(consumer);
        vm.expectRevert(IdentityRegistry.InvalidAssertion.selector);
        reg.approve(user, ACTION, p);
    }

    function test_userWithoutPasskeyCannotApprove() public {
        IdentityRegistry.Proof memory p = _proof(reg, PHONE, user, consumer, ACTION);
        vm.prank(consumer);
        vm.expectRevert(IdentityRegistry.NoPasskey.selector);
        reg.approve(makeAddr("nobody"), ACTION, p);
    }

    function test_firstPasskeyOnlyOnce() public {
        (bytes32 qx, bytes32 qy) = _pubkey(LAPTOP);
        vm.prank(user);
        vm.expectRevert(IdentityRegistry.AlreadyRegistered.selector);
        reg.registerFirstPasskey(qx, qy);
    }

    function test_secondDeviceNeedsApprovalFromFirst() public {
        (bytes32 qx, bytes32 qy) = _pubkey(LAPTOP);
        IdentityRegistry.Proof memory p =
            _proof(reg, PHONE, user, address(reg), keccak256(abi.encode("addPasskey", qx, qy)));
        vm.prank(user);
        reg.addPasskey(qx, qy, p);
        assertEq(reg.keyCount(user), 2);

        // The new device can now approve actions.
        IdentityRegistry.Proof memory fromLaptop = _proof(reg, LAPTOP, user, consumer, ACTION);
        vm.prank(consumer);
        reg.approve(user, ACTION, fromLaptop);
    }

    function test_cannotRemoveLastKey() public {
        (bytes32 qx, bytes32 qy) = _pubkey(PHONE);
        bytes32 keyId = reg.keyIdOf(qx, qy);
        IdentityRegistry.Proof memory p = _proof(reg, PHONE, user, address(reg), keccak256(abi.encode("removePasskey", keyId)));
        vm.prank(user);
        vm.expectRevert(IdentityRegistry.LastKey.selector);
        reg.removePasskey(keyId, p);
    }

    function test_recoveryRetiresOldKeysAfterDelay() public {
        _setGuardian();
        (bytes32 nx, bytes32 ny) = _pubkey(NEW_PHONE);
        vm.prank(guardianAddr);
        reg.startRecovery(user, nx, ny);

        vm.expectRevert();
        reg.completeRecovery(user); // too early
        vm.warp(block.timestamp + 3 days);
        reg.completeRecovery(user);

        // Old phone is retired, new phone works.
        IdentityRegistry.Proof memory oldP = _proof(reg, PHONE, user, consumer, ACTION);
        vm.prank(consumer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UnknownKey.selector, oldP.keyId));
        reg.approve(user, ACTION, oldP);
        IdentityRegistry.Proof memory fromNewPhone = _proof(reg, NEW_PHONE, user, consumer, ACTION);
        vm.prank(consumer);
        reg.approve(user, ACTION, fromNewPhone);
    }

    function test_userCanCancelAMaliciousRecovery() public {
        _setGuardian();
        (bytes32 nx, bytes32 ny) = _pubkey(NEW_PHONE);
        vm.prank(guardianAddr);
        reg.startRecovery(user, nx, ny);
        IdentityRegistry.Proof memory p = _proof(reg, PHONE, user, address(reg), keccak256("cancelRecovery"));
        vm.prank(user);
        reg.cancelRecovery(p);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(IdentityRegistry.NoRecovery.selector);
        reg.completeRecovery(user);
    }

    function test_onlyGuardianStartsRecovery() public {
        _setGuardian();
        (bytes32 nx, bytes32 ny) = _pubkey(NEW_PHONE);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IdentityRegistry.OnlyGuardian.selector);
        reg.startRecovery(user, nx, ny);
    }

    function _setGuardian() internal {
        IdentityRegistry.Proof memory p =
            _proof(reg, PHONE, user, address(reg), keccak256(abi.encode("setGuardian", guardianAddr)));
        vm.prank(user);
        reg.setGuardian(guardianAddr, p);
    }
}
