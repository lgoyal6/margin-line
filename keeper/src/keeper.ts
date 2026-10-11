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
//
// Env: KEEPER_KEY (hex private key), RPC_URL (default Monad testnet), DEPLOYMENT (path to the
// deployment JSON written by script/Deploy.s.sol). Logs are JSON lines on stdout.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  formatEther,
  http,
  parseAbiItem,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = resolve(import.meta.dirname, "..", "..");
const RPC_URL = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const DEPLOYMENT = process.env.DEPLOYMENT ?? resolve(ROOT, "deployments/monad-testnet.json");
const POLL_MS = Number(process.env.POLL_MS ?? 100);
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
const pub = createPublicClient({ chain, transport: http(RPC_URL) });
const wallet = createWalletClient({ chain, transport: http(RPC_URL), account });

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

const lines = new Set<Address>();
const busy = new Set<Address>();
let scannedTo = BigInt(deployment.deployedAtBlock) - 1n;

async function discover(upTo: bigint) {
  while (scannedTo < upTo) {
    const from = scannedTo + 1n;
    const to = from + LOG_WINDOW - 1n < upTo ? from + LOG_WINDOW - 1n : upTo;
    const logs = await pub.getLogs({ address: deployment.manager, event: lineOpened, fromBlock: from, toBlock: to });
    for (const l of logs) {
      const line = l.args.line as Address;
      if (!lines.has(line)) {
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
  const serializedTransaction = await account.signTransaction({
    chainId: chain.id,
    type: "eip1559",
    to: address,
    data,
    gas,
    nonce,
    maxFeePerGas,
    maxPriorityFeePerGas,
  });
  let receipt;
  try {
    receipt = await pub.sendRawTransactionSync({ serializedTransaction });
    nonce++;
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

/// One round trip: current block, the freeze threshold, and every known line's state and health.
async function snapshot(known: Address[]) {
  const results = await pub.multicall({
    multicallAddress: multicall3,
    allowFailure: true,
    contracts: [
      { address: multicall3, abi: multicallAbi, functionName: "getBlockNumber" },
      { address: deployment.manager, abi: managerAbi, functionName: "riskParams" },
      ...known.flatMap((l) => [
        { address: l, abi: lineAbi, functionName: "state" },
        { address: l, abi: lineAbi, functionName: "healthBps" },
      ]),
    ],
  });
  const head = results[0].result as bigint;
  const threshold = BigInt((results[1].result as { freezeHealthBps: number }).freezeHealthBps);
  const lineViews = known.map((line, i) => ({
    line,
    state: Number(results[2 + 2 * i].result),
    health: results[3 + 2 * i].result as bigint | undefined,
  }));
  return { head, threshold, lineViews };
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

  let lastDiscovery = 0n;
  for (;;) {
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
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

main();
