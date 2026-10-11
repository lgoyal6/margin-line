// Replays the worst real day in Perpl's mainnet history (data/worst_day.py picks it: most liquidations)
// on a fresh local fork, minute by minute, against credit lines sized like real approved traders, with
// the keeper's freeze, unwind and settle calls run as health crosses the freeze threshold.
//
// Asserts, every minute and at every settlement:
//   1. no line costs the pool more than its principal;
//   2. pool losses are taken from the reserve, then junior, then senior;
//   3. seniorAssets + juniorAssets + reserve == AUSD held by the pool + principalOutstanding.
//
// How the fork is made to follow the day (fork only, through anvil impersonation of Perpl's owner):
// - the BTC mark is set each minute with updateMarkPricePNSByOwner, scaled to the fork's starting mark;
// - the forked testnet order book does not move with the replayed mark and would fill trades at stale,
//   flattering prices, so sweepers first take out every stale bid and ask the replay could reach
//   (and every fill is checked to come from the replay's own makers). Two
//   market-maker accounts then post exactly the liquidity each trade needs: opens fill at the mark, and
//   unwinds fill at the edge of TradeGuard's band, the worst price the contract allows.
//
// Scenarios (each from the same post-setup snapshot):
//   A  approved terms (score limit = 2x deposit), positions held from midnight, keeper every minute
//   B  approved terms, shorts enter at the day's low and longs at its high, keeper every minute
//   C  stress beyond the score: the market's maximum terms (3x deposit), worst entries, keeper every minute
//   D  as C, but the keeper is offline all day and runs once at the close. Exercises the loss waterfall.
//
// Run: app/scripts/local-chain.sh (do NOT run fork-mark.sh), then
//      node --experimental-strip-types e2e/src/worst-day.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createWalletClient, decodeEventLog, http, parseAbi, type Abi, type Address, type Hex, type TransactionReceipt } from "viem";
import { addr, chain, d, erc20, fund, identityAbi, p256Point, pub, send, wallet } from "./forkkit.ts";

const out = "e2e/evidence/worst-day";
mkdirSync(out, { recursive: true });
const day = JSON.parse(readFileSync(`${out}/day.json`, "utf8"));
const abiOf = (c: string) => JSON.parse(readFileSync(`out/${c}.sol/${c}.json`, "utf8")).abi as Abi;
const poolAbi = abiOf("CreditPool");
const lineAbi = abiOf("CreditLine");
const managerAbi = abiOf("CreditManager");
const guardAbi = abiOf("TradeGuard");

const BTC = 16n; // testnet fork; mainnet BTC is perp 1
const BPS = 10_000n;
const FREEZE_GAS = 380_000n; // keeper.ts's measured ceiling
const UNWIND_GAS = 1_500_000n;
const SETTLE_GAS = 1_500_000n;
const TRADE_GAS = 900_000n;
const multicall3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
const KEEPER = "0x00000000000000000000000000000000000ce1e1" as Address;
const MM_ASK = "0x000000000000000000000000000000000000a5c1" as Address; // only ever sells (OpenShort)
const MM_BID = "0x000000000000000000000000000000000000b1d1" as Address; // only ever buys (OpenLong)
const SWEEP_BUY = "0x0000000000000000000000000000000000005ee9" as Address; // takes the stale testnet asks once
const SWEEP_SELL = "0x0000000000000000000000000000000000005ee8" as Address; // takes the stale testnet bids once

const ex = parseAbi([
  "struct O { uint256 orderDescId; uint256 perpId; uint8 orderType; uint256 orderId; uint256 pricePNS; uint256 lotLNS; uint256 expiryBlock; bool postOnly; bool fillOrKill; bool immediateOrCancel; uint256 maxMatches; uint256 leverageHdths; uint256 lastExecutionBlock; uint256 amountCNS; uint256 maxNegPnlCollatBPS; }",
  "struct Sig { uint256 perpId; uint256 orderId; }",
  "function owner() view returns (address)",
  "function getNextPriceAboveWithOrders(uint256,uint256) view returns (uint256)",
  "function getVolumeAtBookPrice(uint256,uint256) view returns (uint256 bids, uint256 expBids, uint256 asks, uint256 expAsks)",
  "function updateMarkPricePNSByOwner(uint256,uint32)",
  "function createAccount(uint256) returns (uint256)",
  "function execOrder(O) returns (Sig)",
  "function getAccountByAddr(address) view returns ((uint256 accountId, uint256 balanceCNS, uint256 lockedBalanceCNS, uint8 frozen, address accountAddr, (uint256) positions))",
  "event MakerOrderFilled(uint256 perpId, uint256 accountId, uint256 orderId, uint256 pricePNS, uint256 lotLNS, uint256 feeCNS, uint256 lockedBalanceCNS, int256 amountCNS, uint256 balanceCNS)",
  "event MakerOrderFilledV2(uint256 perpId, uint256 accountId, uint256 orderId, uint256 pricePNS, uint256 lotLNS, uint256 feeCNS, uint256 lockedBalanceCNS, int256 amountCNS, uint256 balanceCNS, uint256 builderId, uint256 builderFeeCNS)",
  "function getPositionV2(uint256 perpId, uint256 accountId) view returns ((uint256 accountId, uint256 nextNodeId, uint256 prevNodeId, uint8 positionType, uint256 depositCNS, uint256 pricePNS, uint256 lotLNS, uint256 entryBlock, int256 pnlCNS, int256 deltaPnlCNS, int256 premiumPnlCNS, uint256 priceResiduePNSQ16), uint256, bool)",
  "function getPerpetualInfoV2(uint256) view returns ((string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256 markPNS,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256 numOrders,bool,uint256))",
]);
const accountIdAbi = parseAbi(["function account() view returns (address)", "function accountId() view returns (uint256)"]);

type Tx = Record<string, unknown>;
const rpc = (method: string, params: unknown[] = []) => pub.request({ method: method as never, params: params as never });

/** Send as any address on the fork (anvil impersonation), with an explicit gas ceiling. */
async function as(who: Address, tx: Tx, gas = 3_000_000n): Promise<TransactionReceipt> {
  await rpc("anvil_impersonateAccount", [who]);
  const w = createWalletClient({ account: who, chain, transport: http(chain.rpcUrls.default.http[0]) });
  const hash = await w.writeContract({ ...tx, gas } as never);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`reverted as ${who}: ${String(tx.functionName)}`);
  return r;
}

let owner: Address;
let P0 = 0n; // fork's BTC mark when the replay starts; the day's path is scaled to it
const markAt = (i: number) => BigInt(Math.round((Number(P0) * day.path.prices[i]) / day.path.prices[0]));
const usd = (micro: bigint) => Number(micro) / 1e6;

async function mark(): Promise<bigint> {
  const info = await pub.readContract({ address: d.exchange, abi: ex, functionName: "getPerpetualInfoV2", args: [BTC] });
  return (info as unknown as bigint[])[11];
}

/** Price levels on the fork's BTC book that hold resting orders, in PNS (Perpl indexes levels in ONS,
 *  which is PNS minus the market's base price). */
async function bookLevels() {
  const info = (await pub.readContract({ address: d.exchange, abi: ex, functionName: "getPerpetualInfoV2", args: [BTC] })) as unknown as bigint[];
  const base = info[23];
  const levels: { price: bigint; bids: bigint; asks: bigint }[] = [];
  let p = 0n;
  for (let guard = 0; guard < 1_000; guard++) {
    const q = await pub.readContract({ address: d.exchange, abi: ex, functionName: "getNextPriceAboveWithOrders", args: [BTC, p] });
    if (q === 0n || q <= p) break;
    const [bids, , asks] = await pub.readContract({ address: d.exchange, abi: ex, functionName: "getVolumeAtBookPrice", args: [BTC, q] });
    levels.push({ price: q + base, bids, asks });
    p = q;
  }
  return levels;
}

/** The forked book was left by testnet traders and does not follow the replayed mark. Perpl refuses
 *  admin cancels (UnableToCancelOrder), so two sweepers take out every stale order the replay's prices
 *  could reach (`lo` to `hi`: its lowest and highest order prices). Perpl only accepts limits within 5%
 *  of the mark, so the mark is moved next to each sweep's limit while it runs. */
async function neutralizeBook(lo: bigint, hi: bigint) {
  const before = await bookLevels();
  const sweeps = [
    { who: SWEEP_BUY, type: 0, limit: hi, mark: (hi * BPS) / 10_300n, lots: before.filter((l) => l.price <= hi).reduce((s, l) => s + l.asks, 0n) },
    { who: SWEEP_SELL, type: 1, limit: lo, mark: (lo * 10_300n) / BPS, lots: before.filter((l) => l.price >= lo).reduce((s, l) => s + l.bids, 0n) },
  ];
  for (const w of sweeps.filter((x) => x.lots > 0n)) {
    await fund(w.who, 10_000_000_000_000n);
    await as(w.who, { address: d.ausd, abi: erc20, functionName: "approve", args: [d.exchange, 10_000_000_000_000n] });
    await as(w.who, { address: d.exchange, abi: ex, functionName: "createAccount", args: [10_000_000_000_000n] });
    await setMark(w.mark);
    const order = { orderDescId: 0n, perpId: BTC, orderType: w.type, orderId: 0n, pricePNS: w.limit, lotLNS: w.lots, expiryBlock: 0n, postOnly: false,
      fillOrKill: false, immediateOrCancel: true, maxMatches: 500n, leverageHdths: 100n, lastExecutionBlock: 0n, amountCNS: 0n, maxNegPnlCollatBPS: 10_000n };
    await as(w.who, { address: d.exchange, abi: ex, functionName: "execOrder", args: [order] }, 30_000_000n);
  }
  await setMark(P0);
  const after = await bookLevels();
  return { boughtLots: sweeps[0].lots, soldLots: sweeps[1].lots,
    staleAsksInRange: after.filter((l) => l.asks > 0n && l.price <= hi).length, staleBidsInRange: after.filter((l) => l.bids > 0n && l.price >= lo).length,
    bestStaleBid: after.filter((l) => l.bids > 0n).reduce((m, l) => (l.price > m ? l.price : m), 0n),
    bestStaleAsk: after.filter((l) => l.asks > 0n).reduce((m, l) => (m === 0n || l.price < m ? l.price : m), 0n) };
}

/** A market maker posts a resting order (post-only) for exactly `lots` at `price`. */
async function provide(side: "ask" | "bid", price: bigint, lots: bigint) {
  const order = { orderDescId: 0n, perpId: BTC, orderType: side === "ask" ? 1 : 0, orderId: 0n, pricePNS: price, lotLNS: lots, expiryBlock: 0n,
    postOnly: true, fillOrKill: false, immediateOrCancel: false, maxMatches: 0n, leverageHdths: 100n, lastExecutionBlock: 0n, amountCNS: 0n,
    maxNegPnlCollatBPS: 10_000n };
  await as(side === "ask" ? MM_ASK : MM_BID, { address: d.exchange, abi: ex, functionName: "execOrder", args: [order] });
}

async function setMark(price: bigint) {
  await as(owner, { address: d.exchange, abi: ex, functionName: "updateMarkPricePNSByOwner", args: [BTC, Number(price)] });
}

async function poolState() {
  const fns = ["seniorAssets", "juniorAssets", "reserve", "principalOutstanding", "totalLosses"] as const;
  const r = await pub.multicall({ multicallAddress: multicall3, allowFailure: false, contracts: [
    ...fns.map((f) => ({ address: d.pool as Address, abi: poolAbi, functionName: f })),
    { address: d.ausd as Address, abi: erc20, functionName: "balanceOf", args: [d.pool] },
  ] }) as bigint[];
  return { senior: r[0], junior: r[1], reserve: r[2], principalOutstanding: r[3], totalLosses: r[4], held: r[5] };
}

type Trader = { perplAccount: number; limitMicro: number; maxDepositMicro: number; avgLevBps: number; aprBps: number; side: "long" | "short" };
type Line = {
  trader: number; side: "long" | "short"; borrower: Address; key: number; line?: Address; deposit: bigint; principal: bigint;
  levHdths: bigint; entryMinute: number; entryMark?: bigint; lots?: bigint; notional?: bigint;
  minHealthBps?: bigint; minHealthMinute?: number; frozenAt?: number; frozenHealthBps?: bigint; unwound?: { minute: number; mark: bigint; fillPrice: bigint; lots: bigint }[];
  settled?: { minute: number; recovered: bigint; bounty: bigint; principalRepaid: bigint; interestPaid: bigint; principalLost: bigint; toBorrower: bigint };
  endHealthBps?: bigint; endShortfall?: bigint;
};

const makerIds = new Set<bigint>();

/** Every fill in `r` must come from one of our market makers, at `price`, for `lots` in total: proof
 *  that no stale testnet order filled the trade at a better price than the replay intends. */
function assertFills(r: TransactionReceipt, price: bigint, lots: bigint, what: string) {
  let filled = 0n;
  for (const log of r.logs) {
    let e: { eventName: string; args: { accountId: bigint; pricePNS: bigint; lotLNS: bigint } };
    try {
      e = decodeEventLog({ abi: ex, data: log.data, topics: log.topics }) as typeof e;
    } catch { continue; }
    if (e.eventName !== "MakerOrderFilled" && e.eventName !== "MakerOrderFilledV2") continue;
    assert(makerIds.has(e.args.accountId), `${what}: filled by stale testnet account ${e.args.accountId}`);
    assert(e.args.pricePNS === price, `${what}: filled at ${e.args.pricePNS}, expected ${price}`);
    filled += e.args.lotLNS;
  }
  assert(filled === lots, `${what}: filled ${filled} of ${lots} lots`);
}

async function openLine(l: Line, i: number, aprBps: number) {
  const m = markAt(i);
  await fund(l.borrower, l.deposit);
  await send(wallet(l.key), { address: d.identity, abi: identityAbi, functionName: "registerFirstPasskey", args: p256Point() });
  const now = (await pub.getBlock()).timestamp;
  await send(wallet(0), { address: d.manager, abi: managerAbi, functionName: "approve", args: [l.borrower, l.principal, aprBps, Number(now) + 86_400 * 3] });
  await send(wallet(l.key), { address: d.ausd, abi: erc20, functionName: "approve", args: [d.manager, l.deposit] });
  await send(wallet(l.key), { address: d.manager, abi: managerAbi, functionName: "openLine", args: [l.deposit, l.principal] });
  l.line = (await pub.readContract({ address: d.manager, abi: managerAbi, functionName: "activeLine", args: [l.borrower] })) as Address;

  // Size: the trader's own leverage (capped by the guard) on 98% of the line's money (the rest pays
  // fees), capped by the guard's per-market exposure limit. Notional in AUSD micro = price * lots here.
  const cap = (await pub.readContract({ address: d.guard, abi: guardAbi, functionName: "exposureCap", args: [BTC] })) as bigint;
  let notional = ((l.deposit + l.principal) * 98n * l.levHdths) / 10_000n;
  if (notional > (cap * 99n) / 100n) notional = (cap * 99n) / 100n;
  l.lots = notional / m;
  l.notional = l.lots * m;
  l.entryMark = m;
  await provide(l.side === "long" ? "ask" : "bid", m, l.lots);
  const order = { orderDescId: 0n, perpId: BTC, orderType: l.side === "long" ? 0 : 1, orderId: 0n,
    pricePNS: l.side === "long" ? (m * 10_090n) / BPS : (m * 9_910n) / BPS, lotLNS: l.lots, expiryBlock: 0n, postOnly: false,
    fillOrKill: false, immediateOrCancel: true, maxMatches: 50n, leverageHdths: l.levHdths, lastExecutionBlock: 0n, amountCNS: 0n,
    maxNegPnlCollatBPS: 10_000n };
  const hash = await wallet(l.key).writeContract({ address: l.line, abi: lineAbi, functionName: "trade", args: [[order]], gas: TRADE_GAS } as never);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`open ${l.side} reverted`);
  assertFills(r, m, l.lots, `line ${l.trader} open`);
  const pos = await position(l.line);
  if (pos.lotLNS !== l.lots) throw new Error(`open filled ${pos.lotLNS} of ${l.lots} lots`);
}

async function position(line: Address) {
  const acct = (await pub.readContract({ address: line, abi: accountIdAbi, functionName: "account" })) as Address;
  const id = (await pub.readContract({ address: acct, abi: accountIdAbi, functionName: "accountId" })) as bigint;
  const [pos] = await pub.readContract({ address: d.exchange, abi: ex, functionName: "getPositionV2", args: [BTC, id] });
  return pos as { positionType: number; lotLNS: bigint; pricePNS: bigint };
}

const checks: string[] = [];
function assert(ok: boolean, what: string) {
  if (!ok) throw new Error(`ASSERTION FAILED: ${what}`);
}

/** Keeper pass: the same calls as keeper/src/keeper.ts, with fixed gas ceilings. */
async function keeperPass(lines: Line[], i: number) {
  const open = lines.filter((l) => l.line && !l.settled);
  if (open.length === 0) return;
  const [params, ...views] = await pub.multicall({ multicallAddress: multicall3, allowFailure: false, contracts: [
    { address: d.manager as Address, abi: managerAbi, functionName: "riskParams" },
    ...open.flatMap((l) => [{ address: l.line!, abi: lineAbi, functionName: "state" }, { address: l.line!, abi: lineAbi, functionName: "healthBps" }]),
  ] }) as unknown[];
  const threshold = BigInt((params as { freezeHealthBps: number }).freezeHealthBps);
  for (const [k, l] of open.entries()) {
    const state = Number(views[2 * k]);
    const health = views[2 * k + 1] as bigint;
    if (state === 1 && health < threshold) {
      await as(KEEPER, { address: l.line!, abi: lineAbi, functionName: "freeze" }, FREEZE_GAS);
      l.frozenAt = i;
      l.frozenHealthBps = health;
    }
    if (state === 2 || l.frozenAt !== undefined) await unwindAndSettle(l, i);
  }
}

async function unwindAndSettle(l: Line, i: number) {
  const pos = await position(l.line!);
  l.unwound ??= [];
  if (pos.lotLNS > 0n) {
    const isLong = pos.positionType === 0;
    const price = (await pub.readContract({ address: d.guard, abi: guardAbi, functionName: "closePrice", args: [d.exchange, BTC, isLong] })) as bigint;
    await provide(isLong ? "bid" : "ask", price, pos.lotLNS); // liquidity at the band edge: the worst fill the contract accepts
    const r = await as(KEEPER, { address: l.line!, abi: lineAbi, functionName: "unwind", args: [BTC, pos.lotLNS] }, UNWIND_GAS);
    assertFills(r, price, pos.lotLNS, `line ${l.trader} unwind`);
    l.unwound.push({ minute: i, mark: markAt(i), fillPrice: price, lots: pos.lotLNS });
  }
  const before = await poolState();
  const r = await as(KEEPER, { address: l.line!, abi: lineAbi, functionName: "settleFrozen" }, SETTLE_GAS);
  const after = await poolState();
  checkSettlement(l, i, r, before, after);
}

function checkSettlement(l: Line, i: number, r: TransactionReceipt, before: Awaited<ReturnType<typeof poolState>>, after: Awaited<ReturnType<typeof poolState>>) {
  let closed: Record<string, bigint> | undefined;
  let interest = { toReserve: 0n, toSenior: 0n, toJunior: 0n };
  let loss = { fromReserve: 0n, fromJunior: 0n, fromSenior: 0n };
  for (const log of r.logs) {
    for (const abi of [lineAbi, poolAbi]) {
      try {
        const e = decodeEventLog({ abi, data: log.data, topics: log.topics }) as { eventName: string; args: Record<string, bigint> };
        if (e.eventName === "Closed") closed = e.args;
        if (e.eventName === "InterestAllocated") interest = e.args as typeof interest;
        if (e.eventName === "LossAllocated") loss = e.args as typeof loss;
        break;
      } catch { /* not this contract's event */ }
    }
  }
  assert(closed !== undefined, `line ${l.trader} settled without a Closed event`);
  const lost = closed!.principalLost;
  l.settled = { minute: i, recovered: closed!.recovered, bounty: closed!.bountyPaid, principalRepaid: closed!.principalRepaid,
    interestPaid: closed!.interestPaid, principalLost: lost, toBorrower: closed!.toBorrower };

  // 1. A line never costs the pool more than its principal.
  assert(lost <= l.principal, `line ${l.trader} lost ${lost} > principal ${l.principal}`);
  assert(closed!.principalRepaid + lost === l.principal, `line ${l.trader}: repaid + lost != principal`);
  // 2. Waterfall: interest lands first, then the loss is taken from reserve, then junior, then senior.
  const reserve = before.reserve + interest.toReserve;
  const junior = before.junior + interest.toJunior;
  const senior = before.senior + interest.toSenior;
  const fromReserve = lost < reserve ? lost : reserve;
  const fromJunior = lost - fromReserve < junior ? lost - fromReserve : junior;
  assert(loss.fromReserve + loss.fromJunior + loss.fromSenior === lost, `line ${l.trader}: allocated loss != principal lost`);
  assert(loss.fromReserve === fromReserve && loss.fromJunior === fromJunior && loss.fromSenior === lost - fromReserve - fromJunior,
    `line ${l.trader}: loss not taken reserve -> junior -> senior`);
  assert(after.reserve === reserve - loss.fromReserve && after.junior === junior - loss.fromJunior && after.senior === senior - loss.fromSenior,
    `line ${l.trader}: tranche balances do not match the allocation`);
  assert(after.totalLosses - before.totalLosses === lost, `line ${l.trader}: totalLosses moved by the wrong amount`);
}

async function identity(i: number) {
  const s = await poolState();
  assert(s.senior + s.junior + s.reserve === s.held + s.principalOutstanding,
    `minute ${i}: senior ${s.senior} + junior ${s.junior} + reserve ${s.reserve} != held ${s.held} + outstanding ${s.principalOutstanding}`);
  return s;
}

type Scenario = { name: string; terms: "approved" | "marketMax"; entry: "open" | "worst"; keeper: "everyMinute" | "atClose"; about: string };

async function runScenario(sc: Scenario, maxLevOnDepositBps: bigint, maxLine: bigint, guardLevHdths: bigint) {
  const low = day.path.prices.indexOf(Math.min(...day.path.prices));
  const high = day.path.prices.indexOf(Math.max(...day.path.prices));
  const lines: Line[] = (day.traders as Trader[]).map((t, k) => {
    const deposit = BigInt(t.maxDepositMicro);
    let principal = sc.terms === "approved" ? BigInt(t.limitMicro) : (deposit * maxLevOnDepositBps) / BPS;
    if (principal > (deposit * maxLevOnDepositBps) / BPS) principal = (deposit * maxLevOnDepositBps) / BPS;
    if (principal > maxLine) principal = maxLine;
    const lev = BigInt(Math.floor(t.avgLevBps / 100));
    return { trader: t.perplAccount, side: t.side, key: k + 1, borrower: addr(k + 1), deposit, principal,
      levHdths: lev < guardLevHdths ? lev : guardLevHdths, entryMinute: sc.entry === "open" ? 0 : t.side === "short" ? low : high };
  });
  const apr = new Map((day.traders as Trader[]).map((t) => [t.perplAccount, t.aprBps]));
  const start = await identity(-1);
  const trace: (number | string)[][] = [];
  for (let i = 0; i < day.path.prices.length; i++) {
    if (i > 0) await rpc("evm_increaseTime", [60]);
    await setMark(markAt(i));
    for (const l of lines.filter((x) => x.entryMinute === i)) await openLine(l, i, apr.get(l.trader)!);
    if (sc.keeper === "everyMinute" || i === day.path.prices.length - 1) await keeperPass(lines, i);
    const live = lines.filter((l) => l.line && !l.settled);
    const health = live.length ? (await pub.multicall({ multicallAddress: multicall3, allowFailure: false,
      contracts: live.map((l) => ({ address: l.line!, abi: lineAbi, functionName: "healthBps" })) }) as bigint[]) : [];
    live.forEach((l, k) => {
      if (l.minHealthBps === undefined || health[k] < l.minHealthBps) { l.minHealthBps = health[k]; l.minHealthMinute = i; }
    });
    await identity(i);
    if (i % 10 === 0 || live.length !== lines.filter((l) => l.line).length) trace.push([i, Number(markAt(i)), ...lines.map((l) => {
      const k = live.indexOf(l);
      return k >= 0 ? Number(health[k]) : l.settled ? "settled" : "";
    })]);
    if (i % 240 === 0) console.log(`  ${sc.name} minute ${i}: mark ${usd(markAt(i) * 100_000n).toFixed(1)}, open lines ${live.length}`);
  }
  // Lines still open at the close: what the pool would lose if each were written off now.
  for (const l of lines.filter((x) => x.line && !x.settled)) {
    const [eq, debt, h] = (await pub.multicall({ multicallAddress: multicall3, allowFailure: false, contracts: [
      { address: l.line!, abi: lineAbi, functionName: "equity" }, { address: l.line!, abi: lineAbi, functionName: "debt" },
      { address: l.line!, abi: lineAbi, functionName: "healthBps" }] })) as bigint[];
    l.endHealthBps = h;
    l.endShortfall = debt > eq ? debt - eq : 0n;
    assert(l.endShortfall <= l.principal, `line ${l.trader}: open shortfall ${l.endShortfall} > principal`);
  }
  const end = await identity(day.path.prices.length);
  writeFileSync(`${out}/trace-${sc.name}.json`, JSON.stringify({ columns: ["minute", "markPNS", ...lines.map((l) => `${l.trader}-${l.side}-healthBps`)], rows: trace }) + "\n");
  return { ...sc, start, end, lines };
}

const json = (v: unknown) => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString() : x), 1);

async function main() {
  owner = (await pub.readContract({ address: d.exchange, abi: ex, functionName: "owner" })) as Address;
  await rpc("anvil_setBalance", [owner, "0x56BC75E2D63100000"]);
  await rpc("anvil_setBalance", [KEEPER, "0x56BC75E2D63100000"]);
  P0 = await mark();
  await setMark(P0); // Perpl refuses orders on a mark older than a minute; the fork's clock jumped a day
  // Every price a replay order can carry: opens at mark +-0.9%, unwinds at the band edge (+-1%), plus margin.
  const lo = (markAt(day.path.prices.indexOf(Math.min(...day.path.prices))) * 9_800n) / BPS;
  const hi = (markAt(day.path.prices.indexOf(Math.max(...day.path.prices))) * 10_200n) / BPS;
  const book = await neutralizeBook(lo, hi);
  assert(book.staleAsksInRange === 0 && book.staleBidsInRange === 0, `stale testnet orders left inside the replay's prices: ${json(book)}`);
  console.log(`book: bought ${book.boughtLots} and sold ${book.soldLots} stale lots; nothing stale left between ${lo} and ${hi} (best stale bid ${book.bestStaleBid}, ask ${book.bestStaleAsk})`);
  for (const mm of [MM_ASK, MM_BID]) {
    await fund(mm, 2_000_000_000_000n); // 2M AUSD of collateral each, so the makers never constrain the replay
    await as(mm, { address: d.ausd, abi: erc20, functionName: "approve", args: [d.exchange, 2_000_000_000_000n] });
    await as(mm, { address: d.exchange, abi: ex, functionName: "createAccount", args: [2_000_000_000_000n] });
    makerIds.add((await pub.readContract({ address: d.exchange, abi: ex, functionName: "getAccountByAddr", args: [mm] })).accountId);
  }
  const maxLevOnDepositBps = BigInt((await pub.readContract({ address: d.manager, abi: managerAbi, functionName: "maxLeverageOnDepositBps" })) as number);
  const maxLineBps = BigInt((await pub.readContract({ address: d.manager, abi: managerAbi, functionName: "maxLineBps" })) as number);
  const pool0 = await poolState();
  const maxLine = ((pool0.senior + pool0.junior) * maxLineBps) / BPS;
  const [, guardLev] = (await pub.readContract({ address: d.guard, abi: guardAbi, functionName: "markets", args: [BTC] })) as [boolean, number, number];
  const risk = (await pub.readContract({ address: d.manager, abi: managerAbi, functionName: "riskParams" })) as { freezeHealthBps: number; openHealthBps: number };
  const base = (await rpc("evm_snapshot")) as Hex;

  const scenarios: Scenario[] = [
    { name: "A", terms: "approved", entry: "open", keeper: "everyMinute", about: "approved terms, positions held from midnight UTC, keeper every minute" },
    { name: "B", terms: "approved", entry: "worst", keeper: "everyMinute", about: "approved terms, shorts enter at the day's low and longs at its high, keeper every minute" },
    { name: "C", terms: "marketMax", entry: "worst", keeper: "everyMinute", about: "stress beyond the score: market maximum credit (3x deposit), worst entries, keeper every minute" },
    { name: "D", terms: "marketMax", entry: "worst", keeper: "atClose", about: "stress beyond the score: market maximum credit (3x deposit), worst entries, keeper offline until the close" },
  ];
  const results = [];
  let snap = base;
  for (const sc of scenarios) {
    await rpc("evm_revert", [snap]);
    snap = (await rpc("evm_snapshot")) as Hex;
    console.log(`scenario ${sc.name}: ${sc.about}`);
    const r = await runScenario(sc, maxLevOnDepositBps, maxLine, BigInt(guardLev));
    results.push(r);
    const lost = r.lines.reduce((s, l) => s + (l.settled?.principalLost ?? 0n), 0n);
    console.log(`  frozen ${r.lines.filter((l) => l.frozenAt !== undefined).length}/${r.lines.length}, pool loss ${usd(lost)} AUSD, ` +
      `min health ${r.lines.map((l) => `${l.trader}:${l.minHealthBps}`).join(" ")}`);
  }
  checks.push("every minute of every scenario: seniorAssets + juniorAssets + reserve == AUSD held + principalOutstanding");
  checks.push("every settlement: principalLost <= principal and repaid + lost == principal; loss allocated reserve, then junior, then senior, matching tranche balances and totalLosses");
  checks.push("every open and unwind fill came from the replay's market makers at the intended price for the full size (no stale testnet order filled a line)");
  checks.push("every line still open at the close: max(0, debt - equity) <= principal");
  writeFileSync(`${out}/result.json`, json({
    day: day.worstDay, liquidationsThatDay: day.liquidationsByDay[0], path: { ...day.path, prices: undefined },
    fork: { startMarkPNS: P0, scaledFrom: day.path.open, staleBook: { ...book, replayPriceRange: [lo, hi] }, maxLevOnDepositBps, maxLine, guardLevHdths: guardLev },
    rules: { freezeHealthBps: risk.freezeHealthBps, openHealthBps: risk.openHealthBps, unwindFill: "TradeGuard band edge (worst allowed price)" },
    scenarios: results, checks, pass: true,
  }) + "\n");
  console.log("PASS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
