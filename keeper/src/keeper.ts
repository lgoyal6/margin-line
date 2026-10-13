// Margin Line keeper. Anyone can run this: freezing pays a bounty, and every action it takes is open to
// all callers onchain. It watches each new Monad block, finds active lines whose health has fallen below
// the freeze threshold, freezes them, unwinds their Perpl positions with reduce-only orders, and settles.
//
// Monad specifics handled here:
// - Senders are charged for the gas limit, not gas used, so every send uses a measured estimate plus a
//   small margin instead of a large default.
// - EOAs keep a 10 MON reserve balance; the keeper warns before its wallet gets close.
// - Public RPC caps eth_getLogs at 100 blocks, so line discovery pages in 100-block windows.
// - Speed: the freeze path is one RPC round trip. Nonce and fees are cached, the transaction is signed
//   locally with a fixed measured gas ceiling (no estimate call), and sent with
//   eth_sendRawTransactionSync, which returns the receipt in the same call.
// - Detection is pushed, not polled: over a WebSocket the keeper subscribes to newHeads, which Monad
//   emits as soon as a block is proposed and speculatively executed, and checks lines on each head.
//   Measured on testnet from a laptop: WebSocket round trip 74 ms against about 290 ms over HTTP, and
//   a transaction sent the moment a head arrives lands in the next block 14 times in 20.
// - Deciding without a read: reading health after a block arrives costs the round trip that decides
//   between the next block and the one after. So each check also caches, per line, its equity, debt
//   and Perpl positions, and the keeper subscribes to the logs that change health (Perpl's MarkUpdated,
//   the manager's RiskParamsSet), which Monad pushes with the proposed block. On such a log it
//   recomputes health locally (a position's value moves one for one with the mark) and sends the
//   freeze at once. Interest accrued since the last check is ignored (seconds of interest); a freeze
//   on a line that is in fact healthy reverts and costs its gas limit. The read-then-act path still
//   runs on every block as the backstop. FAST=off disables this path.
//
// Env: KEEPER_KEY (hex private key), RPC_URL (default Monad testnet), WS_URL (default: RPC_URL with
// http(s) replaced by ws(s); set WS_URL=off to poll over HTTP instead), DEPLOYMENT (path to the
// deployment JSON written by script/Deploy.s.sol). Logs are JSON lines on stdout.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  formatEther,
  decodeEventLog,
  http,
  parseAbiItem,
  toEventSelector,
  webSocket,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = resolve(import.meta.dirname, "..", "..");
const RPC_URL = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const DEPLOYMENT = process.env.DEPLOYMENT ?? resolve(ROOT, "deployments/monad-testnet.json");
const WS_URL = process.env.WS_URL ?? RPC_URL.replace(/^http/, "ws");
const POLL_MS = Number(process.env.POLL_MS ?? 100);
const FAST = process.env.FAST !== "off" && WS_URL !== "off";
const LOG_WINDOW = 100n;
const GAS_MARGIN_BPS = 1_200n; // +12% over the estimate
const RESERVE_WARN = 11n * 10n ** 18n; // warn below 11 MON (reserve is 10)
// Fixed gas ceiling for the latency-critical freeze, from measurements on Monad testnet (about 334k
// used). Monad bills the full limit, so this sits just above the measured cost.
const FREEZE_GAS = BigInt(process.env.FREEZE_GAS ?? 380_000);
const REFRESH_BLOCKS = 20n; // how often cached fees are refreshed

const STATE = { Uninitialized: 0, Active: 1, Frozen: 2, Closed: 3 } as const;

type Deployment = {
  chainId: number;
  deployedAtBlock: number;
  manager: Address;
  guard: Address;
  exchange: Address;
};

function log(event: string, fields: Record<string, unknown> = {}) {
  const out: Record<string, unknown> = { t: new Date().toISOString(), event };
  for (const [k, v] of Object.entries(fields)) out[k] = typeof v === "bigint" ? v.toString() : v;
  console.log(JSON.stringify(out));
}

function abiOf(contract: string): Abi {
  const artifact = JSON.parse(readFileSync(resolve(ROOT, `out/${contract}.sol/${contract}.json`), "utf8"));
  return artifact.abi as Abi;
}

const deployment = JSON.parse(readFileSync(DEPLOYMENT, "utf8")) as Deployment;
const key = process.env.KEEPER_KEY as Hex | undefined;
if (!key) throw new Error("KEEPER_KEY is not set");

const chain = defineChain({
  id: deployment.chainId,
  name: "Monad",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});
const account = privateKeyToAccount(key);
const transport = WS_URL === "off" ? http(RPC_URL) : webSocket(WS_URL);
const pub = createPublicClient({ chain, transport });
const wallet = createWalletClient({ chain, transport, account });

const lineAbi = abiOf("CreditLine");
const guardAbi = abiOf("TradeGuard");
const exchangeAbi = [
  parseAbiItem(
    "function getPositionV2(uint256 perpId, uint256 accountId) view returns ((uint256 accountId, uint256 nextNodeId, uint256 prevNodeId, uint8 positionType, uint256 depositCNS, uint256 pricePNS, uint256 lotLNS, uint256 entryBlock, int256 pnlCNS, int256 deltaPnlCNS, int256 premiumPnlCNS, uint256 priceResiduePNSQ16) positionInfo, uint256 markPricePNS, bool markPriceValid)",
  ),
] as const;
const lineOpened = parseAbiItem(
  "event LineOpened(address indexed borrower, address indexed line, uint256 deposit, uint256 principal)",
);
const markUpdated = parseAbiItem("event MarkUpdated(uint256 perpId, uint256 markPNS)");
const riskParamsSet = parseAbiItem(
  "event RiskParamsSet(uint16 freezeHealthBps, uint16 openHealthBps, uint16 sweepHealthBps, uint16 maxLeverageOnDepositBps)",
);
const accountAbi = [
  parseAbiItem("function account() view returns (address)"),
  parseAbiItem("function accountId() view returns (uint256)"),
] as const;
const infoAbi = [
  parseAbiItem(
    "function getPerpetualInfoV2(uint256) view returns ((string name, string symbol, uint256 priceDecimals, uint256 lotDecimals, bytes32 linkFeedId, uint256 priceTolPer100K, uint256 marginTol, uint256 marginTolDecimals, uint256 refPriceMaxAgeSec, uint256 positionBalanceCNS, uint256 insuranceBalanceCNS, uint256 markPNS, uint256 markTimestamp, uint256 lastPNS, uint256 lastTimestamp, uint256 oraclePNS, uint256 oracleTimestampSec, uint256 longOpenInterestLNS, uint256 shortOpenInterestLNS, uint256 fundingStartBlock, int16 fundingRatePct100k, uint256 absFundingClampPctPer100K, uint8 status, uint256 basePricePNS, uint256 maxBidPriceONS, uint256 minBidPriceONS, uint256 maxAskPriceONS, uint256 minAskPriceONS, uint256 numOrders, bool ignOracle, uint256 fundingSumScalingExp))",
  ),
  parseAbiItem("function getExchangeInfo() view returns (uint256, uint256, uint256, uint256 collateralDecimals, address, address)"),
] as const;

const lines = new Set<Address>();
const busy = new Set<Address>();

// Local health model for the read-free freeze, refreshed by every snapshot.
type PositionModel = { perpId: bigint; value: bigint; signedLots: bigint; mark: bigint };
type LineModel = { state: number; rest: bigint; debt: bigint; positions: PositionModel[] };
const models = new Map<Address, LineModel>();
const accountIds = new Map<Address, bigint>();
const marks = new Map<bigint, { mark: bigint; block: bigint }>();
let markets: bigint[] = [];
const pnlScale = new Map<bigint, { num: bigint; den: bigint }>(); // collateral units per lot per price unit
let freezeThreshold = 0n;

/** Health the line would show at the latest known marks, from its last snapshot. */
function estimateHealth(m: LineModel): bigint {
  let equity = m.rest;
  for (const p of m.positions) {
    const now = marks.get(p.perpId)?.mark ?? p.mark;
    const s = pnlScale.get(p.perpId)!;
    const value = p.value + (p.signedLots * (now - p.mark) * s.num) / s.den;
    if (value > 0n) equity += value;
  }
  return m.debt === 0n ? 2n ** 255n : (equity * 10_000n) / m.debt;
}
let scannedTo = BigInt(deployment.deployedAtBlock) - 1n;

async function discover(upTo: bigint) {
  while (scannedTo < upTo) {
    const from = scannedTo + 1n;
    const to = from + LOG_WINDOW - 1n < upTo ? from + LOG_WINDOW - 1n : upTo;
    const logs = await pub.getLogs({ address: deployment.manager, event: lineOpened, fromBlock: from, toBlock: to });
    for (const l of logs) {
      const line = l.args.line as Address;
      if (!lines.has(line)) {
        const acct = (await pub.readContract({ address: line, abi: accountAbi, functionName: "account" })) as Address;
        accountIds.set(line, (await pub.readContract({ address: acct, abi: accountAbi, functionName: "accountId" })) as bigint);
        lines.add(line);
        log("line_discovered", { line, block: l.blockNumber });
      }
    }
    scannedTo = to;
  }
}

// Cached sending state: nonce and fees.
let nonce = 0;
let maxFeePerGas = 0n;
let maxPriorityFeePerGas = 0n;
let refreshedAt = -1n;

async function refresh(head: bigint) {
  if (refreshedAt >= 0n && head - refreshedAt < REFRESH_BLOCKS) return;
  const fees = await pub.estimateFeesPerGas();
  maxFeePerGas = fees.maxFeePerGas;
  maxPriorityFeePerGas = fees.maxPriorityFeePerGas;
  refreshedAt = head;
}

/// Sign locally and send in one round trip. `gas` given means no estimate call (the fast path).
async function send(address: Address, functionName: string, args: unknown[] = [], gas?: bigint) {
  const data = encodeFunctionData({ abi: lineAbi, functionName, args });
  if (gas === undefined) {
    const estimate = await pub.estimateGas({ account, to: address, data });
    gas = (estimate * (10_000n + GAS_MARGIN_BPS)) / 10_000n;
  }
  // The nonce is reserved before sending, so a read-free freeze fired meanwhile cannot reuse it.
  const serializedTransaction = await account.signTransaction({
    chainId: chain.id,
    type: "eip1559",
    to: address,
    data,
    gas,
    nonce: nonce++,
    maxFeePerGas,
    maxPriorityFeePerGas,
  });
  let receipt;
  try {
    receipt = await pub.sendRawTransactionSync({ serializedTransaction });
  } catch (e) {
    nonce = await pub.getTransactionCount({ address: account.address, blockTag: "pending" });
    throw e;
  }
  log("tx", { action: functionName, line: address, hash: receipt.transactionHash, block: receipt.blockNumber, status: receipt.status, gasUsed: receipt.gasUsed, gasLimit: gas });
  if (receipt.status !== "success") throw new Error(`${functionName} reverted`);
  return receipt;
}

const multicall3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
const multicallAbi = [parseAbiItem("function getBlockNumber() view returns (uint256)")] as const;
const managerAbi = abiOf("CreditManager");

/// One round trip: current block, the freeze threshold, and every known line's state and health, plus
/// what the read-free path needs (equity, debt, positions with their marks).
async function snapshot(known: Address[]) {
  const per = 4 + markets.length;
  const results = await pub.multicall({
    multicallAddress: multicall3,
    allowFailure: true,
    contracts: [
      { address: multicall3, abi: multicallAbi, functionName: "getBlockNumber" },
      { address: deployment.manager, abi: managerAbi, functionName: "riskParams" },
      ...known.flatMap((l) => [
        { address: l, abi: lineAbi, functionName: "state" },
        { address: l, abi: lineAbi, functionName: "healthBps" },
        { address: l, abi: lineAbi, functionName: "equity" },
        { address: l, abi: lineAbi, functionName: "debt" },
        ...markets.map((perpId) => ({ address: deployment.exchange, abi: exchangeAbi, functionName: "getPositionV2", args: [perpId, accountIds.get(l) ?? 0n] })),
      ]),
    ],
  });
  const head = results[0].result as bigint;
  const threshold = BigInt((results[1].result as { freezeHealthBps: number }).freezeHealthBps);
  freezeThreshold = threshold;
  const lineViews = known.map((line, i) => {
    const r = results.slice(2 + per * i, 2 + per * (i + 1));
    const state = Number(r[0].result);
    const equity = r[2].result as bigint | undefined;
    const debt = r[3].result as bigint | undefined;
    if (equity !== undefined && debt !== undefined && accountIds.has(line)) {
      const positions: PositionModel[] = [];
      let rest = equity;
      markets.forEach((perpId, k) => {
        const res = r[4 + k].result as unknown as [{ positionType: number; lotLNS: bigint; depositCNS: bigint; pnlCNS: bigint; premiumPnlCNS: bigint }, bigint] | undefined;
        if (!res || res[0].lotLNS === 0n) return;
        const [pos, mark] = res;
        const value = BigInt(pos.depositCNS) + pos.pnlCNS + pos.premiumPnlCNS;
        if (value > 0n) rest -= value;
        positions.push({ perpId, value, signedLots: pos.positionType === 0 ? pos.lotLNS : -pos.lotLNS, mark });
        const known = marks.get(perpId);
        if (!known || head >= known.block) marks.set(perpId, { mark, block: head });
      });
      models.set(line, { state, rest, debt, positions });
    }
    return { line, state, health: r[1].result as bigint | undefined };
  });
  return { head, threshold, lineViews };
}

/// Read-free freeze: a pushed log changed a mark or the threshold; decide from the cached model and
/// send without waiting for any read.
async function fastFreeze(line: Address, estimate: bigint, seenAtBlock: bigint) {
  busy.add(line);
  const n = nonce++;
  try {
    const serializedTransaction = await account.signTransaction({
      chainId: chain.id, type: "eip1559", to: line, data: encodeFunctionData({ abi: lineAbi, functionName: "freeze" }),
      gas: FREEZE_GAS, nonce: n, maxFeePerGas, maxPriorityFeePerGas,
    });
    const hash = await pub.request({ method: "eth_sendRawTransaction", params: [serializedTransaction] });
    log("fast_freeze_sent", { line, estimatedHealth: estimate, threshold: freezeThreshold, seenAtBlock });
    const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 100 });
    log("tx", { action: "freeze", path: "fast", line, hash, block: r.blockNumber, status: r.status, gasUsed: r.gasUsed, gasLimit: FREEZE_GAS });
    if (r.status !== "success") {
      log("fast_freeze_reverted", { line, note: "line was healthy or already frozen" });
      return;
    }
    log("frozen", { line, path: "fast", seenAtBlock, frozenInBlock: r.blockNumber, blocksAfterSeen: r.blockNumber - seenAtBlock });
    models.delete(line);
    await unwindAndSettle(line);
  } catch (e) {
    nonce = await pub.getTransactionCount({ address: account.address, blockTag: "pending" });
    log("error", { line, path: "fast", message: (e as Error).message.split("\n")[0] });
  } finally {
    busy.delete(line);
  }
}

function onHealthLog(l: { address: Address; topics: Hex[]; data: Hex; blockNumber: Hex | bigint }) {
  const block = BigInt(l.blockNumber);
  try {
    if (l.address.toLowerCase() === deployment.manager.toLowerCase()) {
      const e = decodeEventLog({ abi: [riskParamsSet], topics: l.topics as [Hex], data: l.data });
      freezeThreshold = BigInt(e.args.freezeHealthBps);
    } else {
      const e = decodeEventLog({ abi: [markUpdated], topics: l.topics as [Hex], data: l.data });
      const known = marks.get(e.args.perpId);
      if (!pnlScale.has(e.args.perpId) || (known && block < known.block)) return;
      marks.set(e.args.perpId, { mark: e.args.markPNS, block });
    }
  } catch {
    return;
  }
  if (maxFeePerGas === 0n) return;
  for (const [line, m] of models) {
    if (m.state !== STATE.Active || busy.has(line)) continue;
    const h = estimateHealth(m);
    if (h < freezeThreshold) fastFreeze(line, h, block);
  }
}

async function unwindAndSettle(line: Address) {
  const accountAddr = (await pub.readContract({ address: line, abi: lineAbi, functionName: "account" })) as Address;
  const accountId = (await pub.readContract({
    address: accountAddr,
    abi: [parseAbiItem("function accountId() view returns (uint256)")],
    functionName: "accountId",
  })) as bigint;
  const markets = (await pub.readContract({ address: deployment.guard, abi: guardAbi, functionName: "marketIds" })) as bigint[];
  for (const perpId of markets) {
    const [pos] = (await pub.readContract({
      address: deployment.exchange,
      abi: exchangeAbi,
      functionName: "getPositionV2",
      args: [perpId, accountId],
    })) as unknown as [{ lotLNS: bigint }];
    if (pos.lotLNS > 0n) await send(line, "unwind", [perpId, pos.lotLNS]);
  }
  await send(line, "settleFrozen");
  log("settled", { line });
  lines.delete(line);
}

async function handle(line: Address, state: number, health: bigint | undefined, threshold: bigint, head: bigint) {
  if (state === STATE.Closed) {
    lines.delete(line);
    return;
  }
  if (state === STATE.Active) {
    if (health === undefined || health >= threshold) return;
    log("unhealthy", { line, health, threshold, seenAtBlock: head });
    const r = await send(line, "freeze", [], FREEZE_GAS);
    log("frozen", { line, seenAtBlock: head, frozenInBlock: r.blockNumber, blocksAfterSeen: r.blockNumber - head });
  }
  await unwindAndSettle(line);
}

async function main() {
  const balance = await pub.getBalance({ address: account.address });
  log("start", { keeper: account.address, rpc: RPC_URL, manager: deployment.manager, balanceMON: formatEther(balance) });
  if (balance < RESERVE_WARN) log("warn_reserve", { balanceMON: formatEther(balance), note: "Monad keeps a 10 MON reserve per EOA" });
  nonce = await pub.getTransactionCount({ address: account.address, blockTag: "pending" });
  markets = (await pub.readContract({ address: deployment.guard, abi: guardAbi, functionName: "marketIds" })) as bigint[];
  const [, , , collateralDecimals] = (await pub.readContract({ address: deployment.exchange, abi: infoAbi, functionName: "getExchangeInfo" })) as readonly bigint[];
  for (const perpId of markets) {
    const info = (await pub.readContract({ address: deployment.exchange, abi: infoAbi, functionName: "getPerpetualInfoV2", args: [perpId] })) as { priceDecimals: bigint; lotDecimals: bigint };
    pnlScale.set(perpId, { num: 10n ** collateralDecimals, den: 10n ** (info.priceDecimals + info.lotDecimals) });
  }

  let lastDiscovery = 0n;
  async function tick() {
    try {
      const { head, threshold, lineViews } = await snapshot([...lines]);
      await refresh(head);
      for (const v of lineViews) {
        if (busy.has(v.line)) continue;
        busy.add(v.line);
        handle(v.line, v.state, v.health, threshold, head)
          .catch((e) => log("error", { line: v.line, message: (e as Error).message.split("\n")[0] }))
          .finally(() => busy.delete(v.line));
      }
      if (head > lastDiscovery) {
        await discover(head);
        lastDiscovery = head;
      }
    } catch (e) {
      log("loop_error", { message: (e as Error).message.split("\n")[0] });
    }
  }

  if (WS_URL === "off") {
    for (;;) {
      await tick();
      await new Promise((r) => setTimeout(r, POLL_MS));
    }
  }
  // One check per proposed block. A head that arrives mid-check queues exactly one more check, so the
  // keeper never falls behind and never runs two checks at once.
  let running = false;
  let again = false;
  const onHead = async () => {
    if (running) {
      again = true;
      return;
    }
    running = true;
    do {
      again = false;
      await tick();
    } while (again);
    running = false;
  };
  await pub.transport.subscribe({
    params: ["newHeads"],
    onData: onHead,
    onError: (e: Error) => log("ws_error", { message: e.message.split("\n")[0] }),
  });
  log("subscribed", { ws: WS_URL });
  if (FAST) {
    await pub.transport.subscribe({
      params: ["logs", { address: [deployment.exchange, deployment.manager], topics: [[toEventSelector(markUpdated), toEventSelector(riskParamsSet)]] }],
      onData: (d: { result: Parameters<typeof onHealthLog>[0] }) => onHealthLog(d.result),
      onError: (e: Error) => log("ws_error", { message: e.message.split("\n")[0] }),
    });
    log("subscribed_logs", { fast: true });
  }
  await onHead();
}

main();
