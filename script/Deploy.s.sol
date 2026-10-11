// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IExchange} from "perpl-interfaces/IExchange.sol";
import {DelegatedAccountFactory} from "perpl-delegated-account/DelegatedAccountFactory.sol";
import {TrancheVault} from "../src/TrancheVault.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {HistoryLinkRegistry} from "../src/HistoryLinkRegistry.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {RiskLens} from "../src/RiskLens.sol";

interface IAgoraFaucet {
    function requestFunds(address receiver) external;
}

/// @notice Deploys Margin Line against Perpl on Monad testnet: the shared identity and history-link
///         registries, the MarketFactory and RiskLens, then one curator market for BTC created
///         through the factory. Seeds both tranches with faucet AUSD and writes the addresses to
///         deployments/monad-testnet.json.
/// @dev Env: RP_ID (passkey relying-party id, default "localhost"), SEED_LIQUIDITY (AUSD units,
///      default 5,000 AUSD), DEPLOYMENTS_OUT (record path, e.g. deployments/local-fork.json for an
///      anvil fork of testnet). On testnet the deployer is curator, guardian and underwriter, with the
///      minimum 1-day timelock.
contract Deploy is Script {
    IExchange constant EXCHANGE = IExchange(0x1964C32f0bE608E7D29302AFF5E61268E72080cc);
    DelegatedAccountFactory constant FACTORY = DelegatedAccountFactory(0xf42548Ccb3300Bc76c35dc2D347416db2E8d7209);
    IERC20 constant AUSD = IERC20(0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC);
    IAgoraFaucet constant FAUCET = IAgoraFaucet(0xd236c18D274E54FAccC3dd9DDA4b27965a73ee6C);
    uint256 constant BTC = 16;

    // Kept in storage rather than locals: the run body is too large for the stack otherwise.
    IdentityRegistry internal identity;
    HistoryLinkRegistry internal links;
    MarketFactory internal factory;
    RiskLens internal lens;
    MarketFactory.Market internal m;

    function run() external {
        require(block.chainid == 10143, "testnet only");
        string memory rpId = vm.envOr("RP_ID", string("localhost"));
        uint256 seed = vm.envOr("SEED_LIQUIDITY", uint256(5_000e6));
        address deployer = msg.sender;

        vm.startBroadcast();
        identity = new IdentityRegistry(sha256(bytes(rpId)));
        factory = new MarketFactory(AUSD, EXCHANGE, FACTORY, identity);
        links = factory.historyLinks(); // the registry the market's manager reads
        lens = new RiskLens();
        m = factory.createMarket(
            MarketFactory.MarketConfig({
                curatorOwner: deployer,
                guardian: deployer,
                underwriter: deployer,
                timelock: 1 days,
                perpId: BTC,
                maxLeverageHdths: 300, // 3x
                bandBps: 100, // 1%: testnet books are thin
                exposureCap: 10_000e6,
                name: "Margin Line BTC",
                symbol: "mlBTC",
                scorePublisher: deployer,
                publisherBond: 0.1 ether, // MON
                challengeBond: 0.05 ether
            })
        );

        if (AUSD.balanceOf(deployer) < seed) FAUCET.requestFunds(deployer);
        // Junior first, so senior has its cushion: 30% junior, 70% senior.
        uint256 juniorSeed = (seed * 3) / 10;
        AUSD.approve(address(m.junior), juniorSeed);
        m.junior.deposit(juniorSeed, deployer);
        AUSD.approve(address(m.senior), seed - juniorSeed);
        m.senior.deposit(seed - juniorSeed, deployer);
        vm.stopBroadcast();

        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployedAtBlock", block.number);
        vm.serializeString(k, "rpId", rpId);
        vm.serializeAddress(k, "exchange", address(EXCHANGE));
        vm.serializeAddress(k, "accountFactory", address(FACTORY));
        vm.serializeAddress(k, "ausd", address(AUSD));
        vm.serializeAddress(k, "identity", address(identity));
        vm.serializeAddress(k, "historyLinks", address(links));
        vm.serializeAddress(k, "marketFactory", address(factory));
        vm.serializeAddress(k, "riskLens", address(lens));
        vm.serializeAddress(k, "pool", address(m.pool));
        vm.serializeAddress(k, "seniorVault", address(m.senior));
        vm.serializeAddress(k, "juniorVault", address(m.junior));
        vm.serializeAddress(k, "guard", address(m.guard));
        vm.serializeAddress(k, "manager", address(m.manager));
        vm.serializeAddress(k, "lineImplementation", address(m.lineImplementation));
        vm.serializeAddress(k, "breaker", address(m.breaker));
        vm.serializeAddress(k, "scoreOracle", address(m.scoreOracle));
        string memory json = vm.serializeAddress(k, "curator", address(m.curator));
        // Only a real broadcast may replace the record of the live deployment; a simulation must not.
        string memory out = vm.envOr("DEPLOYMENTS_OUT", string("deployments/monad-testnet.json"));
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) vm.writeJson(json, out);
        console2.log(json);
    }
}
