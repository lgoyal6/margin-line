// Phase 4 exit test on Monad testnet: an independent keeper freezes an unhealthy line within one block,
// then unwinds its Perpl position and settles it, earning the freeze bounty.
//
// The line is made unhealthy without moving Perpl's price: the curator tightens the freeze threshold
// above the line's health in block B (instant), and submits the restore, which the timelock releases a
// day later. The keeper runs as a separate process with its own
// key and learns about the line only from chain data. We measure the freeze's block minus B.

import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { p256 } from "@noble/curves/nist.js";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  http,
  parseAbi,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const ROOT = resolve(import.meta.dirname, "..", "..");
const RPC = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const dep = JSON.parse(readFileSync(resolve(ROOT, "deployments/monad-testnet.json"), "utf8"));
const deployerFile = JSON.parse(readFileSync(resolve(ROOT, ".agent-work/secrets/testnet-deployer.json"), "utf8"));
const deployerKey = (Array.isArray(deployerFile.data) ? deployerFile.data[0] : deployerFile.data).private_key as Hex;

const chain = defineChain({
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const pub = createPublicClient({ chain, transport: http(RPC) });

const managerAbi = parseAbi([
  "function approve(address borrower, uint128 limit, uint16 aprBps, uint40 expiry)",
  "function openLine(uint256 deposit, uint256 principal) returns (address)",
  "function activeLine(address) view returns (address)",
  "function setRiskParams((uint16 freezeHealthBps, uint16 openHealthBps, uint16 sweepHealthBps) params, uint16 maxLeverageOnDepositBps)",
  "function riskParams() view returns ((uint16 freezeHealthBps, uint16 openHealthBps, uint16 sweepHealthBps))",
]);
const curatorAbi = parseAbi([
  "function tightenRisk((uint16 freezeHealthBps, uint16 openHealthBps, uint16 sweepHealthBps) p, uint16 maxLeverageOnDepositBps)",
  "function submit(address target, bytes data) returns (bytes32)",
  "function timelock() view returns (uint256)",
  "function pending(bytes32) view returns (uint256)",
]);
const identityAbi = parseAbi(["function registerFirstPasskey(bytes32 qx, bytes32 qy) returns (bytes32)", "function hasPasskey(address) view returns (bool)"]);
const erc20Abi = parseAbi([
  "function approve(address, uint256) returns (bool)",
  "function transfer(address, uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);
const orderType =
  "(uint256 orderDescId, uint256 perpId, uint8 orderType, uint256 orderId, uint256 pricePNS, uint256 lotLNS, uint256 expiryBlock, bool postOnly, bool fillOrKill, bool immediateOrCancel, uint256 maxMatches, uint256 leverageHdths, uint256 lastExecutionBlock, uint256 amountCNS, uint256 maxNegPnlCollatBPS)";
const lineAbi = parseAbi([
  `function trade(${orderType}[] orders)`,
  "function healthBps() view returns (uint256)",
  "function state() view returns (uint8)",
  "function enforcer() view returns (address)",
]);
const exchangeAbi = parseAbi([
  "function getPerpetualInfoV2(uint256) view returns ((string name, string symbol, uint256 priceDecimals, uint256 lotDecimals, bytes32 linkFeedId, uint256 priceTolPer100K, uint256 marginTol, uint256 marginTolDecimals, uint256 refPriceMaxAgeSec, uint256 positionBalanceCNS, uint256 insuranceBalanceCNS, uint256 markPNS, uint256 markTimestamp, uint256 lastPNS, uint256 lastTimestamp, uint256 oraclePNS, uint256 oracleTimestampSec, uint256 longOpenInterestLNS, uint256 shortOpenInterestLNS, uint256 fundingStartBlock, int16 fundingRatePct100k, uint256 absFundingClampPctPer100K, uint8 status, uint256 basePricePNS, uint256 maxBidPriceONS, uint256 minBidPriceONS, uint256 maxAskPriceONS, uint256 minAskPriceONS, uint256 numOrders, bool ignOracle, uint256 fundingSumScalingExp))",
]);
const poolAbi = parseAbi([
  "function principalOf(address) view returns (uint256)",
  "function totalLosses() view returns (uint256)",
]);

const evidence: Record<string, unknown> = {};
const step = (name: string, data: Record<string, unknown>) => {
  evidence[name] = data;
  console.log(JSON.stringify({ step: name, ...data }, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
};

async function main() {
  const deployer = privateKeyToAccount(deployerKey);
  // REUSE=1 reuses the wallets from a previous run (passkey already registered), to save testnet MON.
  const reuse = process.env.REUSE === "1";
  const secretsPath = resolve(ROOT, ".agent-work/secrets/testnet-keeper-liveness.json");
  const keys = reuse
    ? (JSON.parse(readFileSync(secretsPath, "utf8")) as { keeperKey: Hex; borrowerKey: Hex })
    : { keeperKey: generatePrivateKey(), borrowerKey: generatePrivateKey() };
  const { keeperKey, borrowerKey } = keys;
  if (!reuse) {
    mkdirSync(resolve(ROOT, ".agent-work/secrets"), { recursive: true });
    writeFileSync(secretsPath, JSON.stringify(keys), { mode: 0o600 });
  }
  const keeper = privateKeyToAccount(keeperKey);
  const borrower = privateKeyToAccount(borrowerKey);
  const asDeployer = createWalletClient({ chain, transport: http(RPC), account: deployer });
  const asBorrower = createWalletClient({ chain, transport: http(RPC), account: borrower });
  // Fee caps keep each transaction within small testnet balances (base fee is about 100 gwei).
  const fees = { maxFeePerGas: 130_000_000_000n, maxPriorityFeePerGas: 3_000_000_000n };
  const wait = async (hash: Hex, label: string) => {
    const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 200 });
    step(label, { hash, block: r.blockNumber, status: r.status, gasUsed: r.gasUsed });
    if (r.status !== "success") throw new Error(`${label} reverted`);
    return r;
  };
  const settleLag = async (block: bigint) => {
    while ((await pub.getBlockNumber({ cacheTime: 0 })) < block + 4n) await new Promise((r) => setTimeout(r, 300));
  };

  step("actors", { keeper: keeper.address, borrower: borrower.address, reuse });
  const deposit = reuse ? 90_000_000n : 100_000_000n;
  if (reuse) {
    // Top up only what is short, then wait out Monad's lagged balance check.
    let last = 0n;
    if ((await pub.getBalance({ address: keeper.address })) < 300_000_000_000_000_000n) {
      last = (await wait(await asDeployer.sendTransaction({ to: keeper.address, value: 250_000_000_000_000_000n }), "top_up_keeper")).blockNumber;
    }
    if ((await pub.getBalance({ address: borrower.address })) < 250_000_000_000_000_000n) {
      last = (await wait(await asDeployer.sendTransaction({ to: borrower.address, value: 250_000_000_000_000_000n }), "top_up_borrower")).blockNumber;
    }
    if (last) await settleLag(last);
    // Wallets carried over from an earlier deployment have no passkey in this one's registry yet.
    if (!(await pub.readContract({ address: dep.identity, abi: identityAbi, functionName: "hasPasskey", args: [borrower.address] }))) {
      const pk = p256.utils.randomSecretKey();
      const pubkey = p256.getPublicKey(pk, false);
      await wait(await asBorrower.writeContract({ address: dep.identity, abi: identityAbi, functionName: "registerFirstPasskey", args: [toHex(pubkey.slice(1, 33)), toHex(pubkey.slice(33))], ...fees }), "register_passkey");
    }
  } else {
    await wait(await asDeployer.sendTransaction({ to: keeper.address, value: 250_000_000_000_000_000n }), "fund_keeper");
    const f = await wait(await asDeployer.sendTransaction({ to: borrower.address, value: 450_000_000_000_000_000n }), "fund_borrower");
    await wait(await asDeployer.writeContract({ address: dep.ausd, abi: erc20Abi, functionName: "transfer", args: [borrower.address, 100_000_000n] }), "fund_borrower_ausd");
    await settleLag(f.blockNumber);
    // A borrower with a passkey.
    const pk = p256.utils.randomSecretKey();
    const pubkey = p256.getPublicKey(pk, false);
    await wait(await asBorrower.writeContract({ address: dep.identity, abi: identityAbi, functionName: "registerFirstPasskey", args: [toHex(pubkey.slice(1, 33)), toHex(pubkey.slice(33))], ...fees }), "register_passkey");
  }

  // The borrower opens a line sized so its health sits 0.6% above the market's current opening bar (an
  // earlier run may have left the bars tightened), and takes a small BTC long on Perpl's real book.
  const risk = await pub.readContract({ address: dep.manager, abi: managerAbi, functionName: "riskParams" });
  const principal = (deposit * 10_000n) / BigInt(risk.openHealthBps + 60 - 10_000);
  // Resume with an already-open line if a previous attempt got that far.
  let line = (await pub.readContract({ address: dep.manager, abi: managerAbi, functionName: "activeLine", args: [borrower.address] })) as Address;
  if (line === "0x0000000000000000000000000000000000000000") {
    const expiry = Math.floor(Date.now() / 1000) + 86_400;
    await wait(await asDeployer.writeContract({ address: dep.manager, abi: managerAbi, functionName: "approve", args: [borrower.address, principal, 1_000, expiry] }), "underwriter_approve");
    await wait(await asBorrower.writeContract({ address: dep.ausd, abi: erc20Abi, functionName: "approve", args: [dep.manager, deposit], ...fees }), "approve_deposit");
    await wait(await asBorrower.writeContract({ address: dep.manager, abi: managerAbi, functionName: "openLine", args: [deposit, principal], ...fees }), "open_line");
    line = (await pub.readContract({ address: dep.manager, abi: managerAbi, functionName: "activeLine", args: [borrower.address] })) as Address;
  } else {
    step("resumed_line", { line });
  }
  const p = await pub.readContract({ address: dep.exchange, abi: exchangeAbi, functionName: "getPerpetualInfoV2", args: [16n] });
  const ask = p.minAskPriceONS + p.basePricePNS;
  const order = {
    orderDescId: 0n, perpId: 16n, orderType: 0, orderId: 0n, pricePNS: (ask * 1008n) / 1000n, lotLNS: 100n,
    expiryBlock: 0n, postOnly: false, fillOrKill: false, immediateOrCancel: true, maxMatches: 50n,
    leverageHdths: 200n, lastExecutionBlock: 0n, amountCNS: 0n, maxNegPnlCollatBPS: 1000n,
  };
  // Perpl matching cost depends on the book, which can move between estimate and execution; an
  // estimate-sized limit ran out of gas once. Monad bills the limit, so this is a deliberate ceiling.
  await wait(await asBorrower.writeContract({ address: line, abi: lineAbi, functionName: "trade", args: [[order]], gas: 900_000n, ...fees }), "open_btc_long");
  step("line", { line, healthBps: await pub.readContract({ address: line, abi: lineAbi, functionName: "healthBps" }) });

  // Start the independent keeper. Its deployment record starts at the current block, so line discovery
  // (100-block log windows) does not rescan the whole deployment.
  const keeperDeployment = resolve(ROOT, ".agent-work/keeper-liveness-deployment.json");
  writeFileSync(keeperDeployment, JSON.stringify({ ...dep, deployedAtBlock: Number(await pub.getBlockNumber()) - 200 }));
  const proc = spawn(process.execPath, ["--experimental-strip-types", resolve(ROOT, "keeper/src/keeper.ts")], {
    env: { ...process.env, KEEPER_KEY: keeperKey, RPC_URL: RPC, DEPLOYMENT: keeperDeployment },
  });
  const keeperLog: Record<string, unknown>[] = [];
  const seen = new Promise<void>((res) => {
    proc.stdout.on("data", (b: Buffer) => {
      for (const line of b.toString().split("\n").filter(Boolean)) {
        try {
          const e = JSON.parse(line);
          keeperLog.push(e);
          console.log("  keeper:", line);
          if (e.event === "settled") res();
        } catch {
          console.log("  keeper:", line);
        }
      }
    });
  });
  proc.stderr.on("data", (b: Buffer) => console.error("  keeper err:", b.toString()));
  while (!keeperLog.some((e) => e.event === "line_discovered" && e.line === line)) await new Promise((r) => setTimeout(r, 300));

  // Make the line unhealthy in block B by tightening the freeze bar just above its health.
  const freeze = risk.openHealthBps + 100;
  const bar = Math.max(risk.sweepHealthBps, risk.openHealthBps + 200);
  const rB = await wait(
    await asDeployer.writeContract({ address: dep.curator, abi: curatorAbi, functionName: "tightenRisk", args: [{ freezeHealthBps: freeze, openHealthBps: risk.openHealthBps + 200, sweepHealthBps: bar }, 30_000] }),
    "make_unhealthy",
  );
  const timeout = new Promise<void>((_, rej) => setTimeout(() => rej(new Error("keeper did not settle within 120 s")), 120_000));
  await Promise.race([seen, timeout]);
  proc.kill();

  const frozen = keeperLog.find((e) => e.event === "tx" && e.action === "freeze") as { block: string; hash: string };
  step("liveness", {
    unhealthyInBlock: rB.blockNumber,
    frozenInBlock: frozen.block,
    blocksAfterUnhealthy: BigInt(frozen.block) - rB.blockNumber,
    freezeTx: frozen.hash,
  });
  step("outcome", {
    state: await pub.readContract({ address: line, abi: lineAbi, functionName: "state" }),
    enforcer: await pub.readContract({ address: line, abi: lineAbi, functionName: "enforcer" }),
    keeperBountyAUSD: await pub.readContract({ address: dep.ausd, abi: erc20Abi, functionName: "balanceOf", args: [keeper.address] }),
    poolPrincipalOfLine: await pub.readContract({ address: dep.pool, abi: poolAbi, functionName: "principalOf", args: [line] }),
    poolTotalLosses: await pub.readContract({ address: dep.pool, abi: poolAbi, functionName: "totalLosses" }),
  });

  // Restoring is a loosening, so it goes through the curator's timelock: submit now, execute after it.
  const restore = encodeFunctionData({ abi: managerAbi, functionName: "setRiskParams", args: [{ freezeHealthBps: 11_000, openHealthBps: 13_000, sweepHealthBps: 12_500 }, 30_000] });
  const id = keccak256(encodeAbiParameters([{ type: "address" }, { type: "bytes" }], [dep.manager, restore]));
  let at = await pub.readContract({ address: dep.curator, abi: curatorAbi, functionName: "pending", args: [id] });
  if (at === 0n) {
    // Not queued by an earlier run yet.
    const rR = await wait(await asDeployer.writeContract({ address: dep.curator, abi: curatorAbi, functionName: "submit", args: [dep.manager, restore] }), "submit_restore_risk_params");
    at = (await pub.getBlock({ blockNumber: rR.blockNumber })).timestamp + (await pub.readContract({ address: dep.curator, abi: curatorAbi, functionName: "timelock" }));
  }
  step("restore_pending", { target: dep.manager, data: restore, executableAfter: new Date(Number(at) * 1000).toISOString(),
    execute: `cast send ${dep.curator} "execute(address,bytes)" ${dep.manager} ${restore}` });
  evidence.keeperLog = keeperLog;
  mkdirSync(resolve(ROOT, "e2e/evidence"), { recursive: true });
  writeFileSync(resolve(ROOT, `e2e/evidence/${process.env.EVIDENCE ?? `keeper-liveness${reuse ? "-fast" : ""}`}.json`), JSON.stringify(evidence, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
