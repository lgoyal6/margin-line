// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {Passkeys} from "../utils/Passkeys.sol";
import {IdentityRegistry} from "../../src/IdentityRegistry.sol";
import {HistoryLinkRegistry} from "../../src/HistoryLinkRegistry.sol";

/// @notice Identity against the real chain: Monad's P-256 precompile at 0x100 verifies passkey
///         signatures natively, and a real Perpl testnet account can be linked as trading history.
contract IdentityForkTest is Passkeys {
    IExchange constant EXCHANGE = IExchange(0x1964C32f0bE608E7D29302AFF5E61268E72080cc);
    IERC20 constant AUSD = IERC20(0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC);

    function setUp() public {
        if (block.chainid != 10143) vm.skip(true); // testnet addresses
    }

    /// @notice The precompile answers a valid signature with 1 and costs a few thousand gas, versus
    ///         hundreds of thousands for OpenZeppelin's Solidity fallback.
    function test_monadP256PrecompileVerifiesPasskeys() public {
        uint256 pk = 0xA11CE;
        (bytes32 qx, bytes32 qy) = _pubkey(pk);
        bytes32 h = sha256("margin line");
        (bytes32 r, bytes32 s) = vm.signP256(pk, h);
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s));

        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(0x100).staticcall(abi.encode(h, r, s, qx, qy));
        uint256 used = g - gasleft();
        console2.log("P256 precompile gas", used);
        assertTrue(ok);
        assertEq(ret.length, 32, "precompile present");
        assertEq(abi.decode(ret, (uint256)), 1, "signature valid");

        IdentityRegistry reg = new IdentityRegistry(RP_ID_HASH);
        address user = makeAddr("user");
        vm.prank(user);
        reg.registerFirstPasskey(qx, qy);
        IdentityRegistry.Proof memory p = _proof(reg, pk, user, address(this), keccak256("sweep"));
        g = gasleft();
        reg.approve(user, keccak256("sweep"), p);
        console2.log("full WebAuthn approval gas", g - gasleft());
    }

    function test_linkARealPerplTestnetAccount() public {
        uint256 key = 0xBEEF;
        address wallet = vm.addr(key);
        vm.prank(address(EXCHANGE)); // fork-only funding; AUSD storage defeats `deal`
        AUSD.transfer(wallet, 200e6);
        vm.startPrank(wallet);
        AUSD.approve(address(EXCHANGE), 200e6);
        uint256 id = EXCHANGE.createAccount(200e6);
        vm.stopPrank();

        HistoryLinkRegistry links = new HistoryLinkRegistry(EXCHANGE);
        address borrower = makeAddr("borrower");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                links.domainSeparator(),
                keccak256(abi.encode(links.LINK_TYPEHASH(), borrower, id, uint256(0), deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.prank(borrower);
        links.link(id, wallet, deadline, abi.encodePacked(r, s, v));
        assertEq(links.linkedTo(id), borrower);
    }
}
