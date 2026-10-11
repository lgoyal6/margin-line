// Reads and writes against the deployed market. Every figure the app shows comes from here, and
// each read is described by a `Source` so the Explore page can show exactly where a number came from.
import { erc20Abi, maxUint256, zeroAddress, type Address, type Hex } from "viem";
import {
  circuitBreakerAbi, creditLineAbi, creditManagerAbi, creditPoolAbi, iExchangeAbi, riskCuratorAbi, riskLensAbi,
  tradeGuardAbi, trancheVaultAbi,
} from "./abi";
import { BTC_PERP, publicClient, sendAs, walletFor, wait, type Deployment } from "./chain";
import { freezePrice, maxSweep } from "./risk";

export type Source = { contract: string; address: Address; call: string };

// ------------------------------------------------------------ market

export async function readMarket(d: Deployment) {
  const p = { address: d.pool, abi: creditPoolAbi } as const;
  const [senior, junior, reserve, outstanding, idle, utilization, juniorBps, seniorApr, minJunior, maxUtil, interest, losses] =
    await Promise.all([
      publicClient.readContract({ ...p, functionName: "seniorAssets" }),
      publicClient.readContract({ ...p, functionName: "juniorAssets" }),
      publicClient.readContract({ ...p, functionName: "reserve" }),
      publicClient.readContract({ ...p, functionName: "principalOutstanding" }),
      publicClient.readContract({ ...p, functionName: "idle" }),
      publicClient.readContract({ ...p, functionName: "utilizationBps" }),
      publicClient.readContract({ ...p, functionName: "juniorBps" }),
      publicClient.readContract({ ...p, functionName: "seniorAprBps" }),
      publicClient.readContract({ ...p, functionName: "minJuniorBps" }),
      publicClient.readContract({ ...p, functionName: "maxUtilizationBps" }),
      publicClient.readContract({ ...p, functionName: "totalInterestEarned" }),
      publicClient.readContract({ ...p, functionName: "totalLosses" }),
    ]);
  const status = await publicClient.readContract({ address: d.breaker, abi: circuitBreakerAbi, functionName: "globalStatus" });
  return { senior, junior, reserve, outstanding, idle, utilization, juniorBps, seniorApr, minJunior, maxUtil, interest, losses, status };
}

export async function readRules(d: Deployment) {
  const m = { address: d.manager, abi: creditManagerAbi } as const;
  const [risk, maxLev, maxLineBps, bounty, market, exposureCap, underwriter] = await Promise.all([
    publicClient.readContract({ ...m, functionName: "riskParams" }),
    publicClient.readContract({ ...m, functionName: "maxLeverageOnDepositBps" }),
    publicClient.readContract({ ...m, functionName: "maxLineBps" }),
    publicClient.readContract({ ...m, functionName: "freezeBounty" }),
    publicClient.readContract({ address: d.guard, abi: tradeGuardAbi, functionName: "markets", args: [BTC_PERP] }),
    publicClient.readContract({ address: d.guard, abi: tradeGuardAbi, functionName: "exposureCap", args: [BTC_PERP] }),
    publicClient.readContract({ ...m, functionName: "underwriter" }),
  ]);
  const [timelock, guardian] = await Promise.all([
    publicClient.readContract({ address: d.curator, abi: riskCuratorAbi, functionName: "timelock" }),
    publicClient.readContract({ address: d.curator, abi: riskCuratorAbi, functionName: "guardian" }),
  ]);
  return {
    freezeHealthBps: BigInt(risk.freezeHealthBps), openHealthBps: BigInt(risk.openHealthBps),
    sweepHealthBps: BigInt(risk.sweepHealthBps), maxLeverageOnDepositBps: BigInt(maxLev), maxLineBps: BigInt(maxLineBps),
    bountyBps: BigInt(bounty[0]), maxBounty: bounty[1],
    btcAllowed: market[0], maxLeverageHdths: BigInt(market[1]), bandBps: BigInt(market[2]), exposureCap,
    timelock, guardian, underwriter,
  };
}

export async function readBtc(d: Deployment) {
  const info = await publicClient.readContract({ address: d.exchange, abi: iExchangeAbi, functionName: "getPerpetualInfoV2", args: [BTC_PERP] });
  const ex = await publicClient.readContract({ address: d.exchange, abi: iExchangeAbi, functionName: "getExchangeInfo" });
  return {
    markPNS: info.markPNS, priceDecimals: info.priceDecimals, lotDecimals: info.lotDecimals, collateralDecimals: ex[3],
    bestAskPNS: info.minAskPriceONS + info.basePricePNS, bestBidPNS: info.maxBidPriceONS + info.basePricePNS,
    status: info.status,
  };
}

// ------------------------------------------------------------ trader

export async function balances(d: Deployment, user: Address) {
  const [mon, ausd] = await Promise.all([
    publicClient.getBalance({ address: user }),
    publicClient.readContract({ address: d.ausd, abi: erc20Abi, functionName: "balanceOf", args: [user] }),
  ]);
  return { mon, ausd };
}

export async function activeLine(d: Deployment, user: Address): Promise<Address | null> {
  const line = await publicClient.readContract({ address: d.manager, abi: creditManagerAbi, functionName: "activeLine", args: [user] });
  return line === zeroAddress ? null : line;
}

export async function approvalOf(d: Deployment, user: Address) {
  const [limit, aprBps, expiry] = await publicClient.readContract({ address: d.manager, abi: creditManagerAbi, functionName: "approvals", args: [user] });
  return { limit: BigInt(limit), aprBps: Number(aprBps), expiry: Number(expiry) };
}

export async function readLine(d: Deployment, line: Address) {
  const l = { address: line, abi: creditLineAbi } as const;
  const [state, principal, debt, equity, health, account, aprBps] = await Promise.all([
    publicClient.readContract({ ...l, functionName: "state" }),
    publicClient.readContract({ ...l, functionName: "principal" }),
    publicClient.readContract({ ...l, functionName: "debt" }),
    publicClient.readContract({ ...l, functionName: "equity" }),
    publicClient.readContract({ ...l, functionName: "healthBps" }),
    publicClient.readContract({ ...l, functionName: "account" }),
    publicClient.readContract({ ...l, functionName: "aprBps" }),
  ]);
  const accountId = await publicClient.readContract({
    address: account, abi: [{ type: "function", name: "accountId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }] as const,
    functionName: "accountId",
  });
  const [acct, posResult] = await Promise.all([
    publicClient.readContract({ address: d.exchange, abi: iExchangeAbi, functionName: "getAccountById", args: [accountId] }),
    publicClient.readContract({ address: d.exchange, abi: iExchangeAbi, functionName: "getPositionV2", args: [BTC_PERP, accountId] }),
  ]);
  const pos = posResult[0];
  return {
    address: line, state: Number(state), principal, debt, equity, health, aprBps: Number(aprBps), accountId,
    freeBalance: acct.balanceCNS, lots: pos.lotLNS, isLong: Number(pos.positionType) === 0,
    positionValue: pos.depositCNS + BigInt(pos.pnlCNS) + BigInt(pos.premiumPnlCNS),
  };
}

export type LineView = Awaited<ReturnType<typeof readLine>>;

export const lineStates = ["Not opened", "Active", "Frozen", "Closed"] as const;

export function lineRisk(line: LineView, btc: Awaited<ReturnType<typeof readBtc>>, rules: Awaited<ReturnType<typeof readRules>>) {
  return {
    freeze: freezePrice({
      markPNS: btc.markPNS, lots: line.lots, isLong: line.isLong, equity: line.equity, debt: line.debt,
      freezeHealthBps: rules.freezeHealthBps, priceDecimals: btc.priceDecimals, lotDecimals: btc.lotDecimals,
      collateralDecimals: btc.collateralDecimals,
    }),
    maxSweep: maxSweep(line.equity, line.debt, rules.sweepHealthBps, line.freeBalance),
  };
}

export async function openLine(d: Deployment, key: Hex, deposit: bigint, principal: bigint) {
  const w = walletFor(key);
  await wait(await w.writeContract({ address: d.ausd, abi: erc20Abi, functionName: "approve", args: [d.manager, deposit] }));
  await wait(await w.writeContract({ address: d.manager, abi: creditManagerAbi, functionName: "openLine", args: [deposit, principal] }));
}

/** One IOC order through the guard. Prices sit at the edge of the guard's band on the side that
 *  fills (buys at mark + band, sells at mark - band), so a thin book still fills within the band. */
export async function trade(
  d: Deployment, key: Hex, line: Address, kind: "long" | "short" | "closeLong" | "closeShort", lots: bigint,
  leverageHdths: bigint, bandBps: bigint,
) {
  const btc = await readBtc(d);
  const type = { long: 0, short: 1, closeLong: 2, closeShort: 3 }[kind];
  const buys = kind === "long" || kind === "closeShort";
  const edge = bandBps > 10n ? bandBps - 10n : bandBps; // stay a little inside the band
  const price = buys ? (btc.markPNS * (10_000n + edge)) / 10_000n : (btc.markPNS * (10_000n - edge)) / 10_000n;
  const order = {
    orderDescId: 0n, perpId: BTC_PERP, orderType: type, orderId: 0n, pricePNS: price, lotLNS: lots, expiryBlock: 0n,
    postOnly: false, fillOrKill: false, immediateOrCancel: true, maxMatches: 50n,
    leverageHdths: type <= 1 ? leverageHdths : 100n, lastExecutionBlock: 0n, amountCNS: 0n, maxNegPnlCollatBPS: 10_000n,
  };
  // Monad charges the full gas limit even on revert, and Perpl matching depends on the book, so the
  // limit is a measured fixed ceiling rather than a tight estimate.
  const w = walletFor(key);
  // Include the guard's and breaker's errors so a refusal from either decodes into words.
  const abi = [...creditLineAbi, ...tradeGuardAbi.filter((x) => x.type === "error"), ...circuitBreakerAbi.filter((x) => x.type === "error")];
  await publicClient.simulateContract({ address: line, abi, functionName: "trade", args: [[order]], account: w.account });
  await wait(await w.writeContract({ address: line, abi: creditLineAbi, functionName: "trade", args: [[order]], gas: 900_000n }));
}

export async function topUp(d: Deployment, key: Hex, line: Address, amount: bigint) {
  const w = walletFor(key);
  await wait(await w.writeContract({ address: d.ausd, abi: erc20Abi, functionName: "approve", args: [line, amount] }));
  await wait(await w.writeContract({ address: line, abi: creditLineAbi, functionName: "topUp", args: [amount] }));
}

// ------------------------------------------------------------ lender

export async function readTranche(d: Deployment, vault: Address, user: Address | null) {
  const v = { address: vault, abi: trancheVaultAbi } as const;
  const [assets, supply, maxDeposit, queueLength, head, queuedShares] = await Promise.all([
    publicClient.readContract({ ...v, functionName: "totalAssets" }),
    publicClient.readContract({ ...v, functionName: "totalSupply" }),
    publicClient.readContract({ ...v, functionName: "maxDeposit", args: [user ?? zeroAddress] }),
    publicClient.readContract({ ...v, functionName: "queueLength" }),
    publicClient.readContract({ ...v, functionName: "head" }),
    publicClient.readContract({ ...v, functionName: "queuedShares" }),
  ]);
  const sharePrice = await publicClient.readContract({ ...v, functionName: "convertToAssets", args: [10n ** 12n] }); // one whole share
  let mine = { shares: 0n, value: 0n, maxWithdraw: 0n };
  const requests: { id: number; shares: bigint; value: bigint; ahead: bigint }[] = [];
  if (user) {
    const shares = await publicClient.readContract({ ...v, functionName: "balanceOf", args: [user] });
    const [value, maxWithdraw] = await Promise.all([
      publicClient.readContract({ ...v, functionName: "convertToAssets", args: [shares] }),
      publicClient.readContract({ ...v, functionName: "maxWithdraw", args: [user] }),
    ]);
    mine = { shares, value, maxWithdraw };
    let ahead = 0n;
    for (let i = Number(head); i < Number(queueLength); i++) {
      const [owner, reqShares] = await publicClient.readContract({ ...v, functionName: "queue", args: [BigInt(i)] });
      const reqValue = await publicClient.readContract({ ...v, functionName: "convertToAssets", args: [reqShares] });
      if (owner.toLowerCase() === user.toLowerCase() && reqShares > 0n) requests.push({ id: i, shares: reqShares, value: reqValue, ahead });
      ahead += reqValue;
    }
  }
  return { assets, supply, sharePrice, maxDeposit: maxDeposit === maxUint256 ? null : maxDeposit, queueLength, head, queuedShares, mine, requests };
}

export async function deposit(d: Deployment, key: Hex, vault: Address, amount: bigint) {
  const w = walletFor(key);
  await wait(await w.writeContract({ address: d.ausd, abi: erc20Abi, functionName: "approve", args: [vault, amount] }));
  await wait(await w.writeContract({ address: vault, abi: trancheVaultAbi, functionName: "deposit", args: [amount, w.account.address] }));
}

export async function withdraw(key: Hex, vault: Address, amount: bigint) {
  const w = walletFor(key);
  await wait(await w.writeContract({ address: vault, abi: trancheVaultAbi, functionName: "withdraw", args: [amount, w.account.address, w.account.address] }));
}

export async function requestRedeem(key: Hex, vault: Address, shares: bigint) {
  await wait(await walletFor(key).writeContract({ address: vault, abi: trancheVaultAbi, functionName: "requestRedeem", args: [shares] }));
}

export async function cancelRequest(key: Hex, vault: Address, id: bigint) {
  await wait(await walletFor(key).writeContract({ address: vault, abi: trancheVaultAbi, functionName: "cancelRequest", args: [id] }));
}

export async function processQueue(key: Hex, vault: Address) {
  await wait(await walletFor(key).writeContract({ address: vault, abi: trancheVaultAbi, functionName: "processQueue", args: [20n] }));
}

// ------------------------------------------------------------ stress

export async function stress(d: Deployment, lines: Address[], moveBps: bigint) {
  return publicClient.readContract({
    address: d.riskLens, abi: riskLensAbi, functionName: "stress",
    args: [d.manager, lines, [{ perpId: BTC_PERP, moveBps }]],
  });
}

// ------------------------------------------------------------ local fork only

/** Local fork only: give a fresh wallet gas money and test AUSD. AUSD comes from Perpl's own balance
 *  through anvil impersonation, which exists only on the fork. */
export async function forkFund(d: Deployment, user: Address, ausd: bigint) {
  await publicClient.request({ method: "anvil_setBalance" as never, params: [user, "0x8AC7230489E80000"] as never }); // 10 MON
  await sendAs(d.exchange, { address: d.ausd, abi: erc20Abi, functionName: "transfer", args: [user, ausd], chain: undefined } as never);
}

/** Local fork only, and labeled as such in the UI: the underwriter approves a demo limit. Real
 *  borrowers open from a published score instead (`openLineWithScore`). */
export async function forkDemoApproval(d: Deployment, user: Address, limit: bigint) {
  const rules = await readRules(d);
  const now = (await publicClient.getBlock()).timestamp; // the fork's clock, which can run ahead of ours
  const expiry = Number(now) + 86_400 * 7;
  await sendAs(rules.underwriter, {
    address: d.manager, abi: creditManagerAbi, functionName: "approve", args: [user, limit, 1_000, expiry], chain: undefined,
  } as never);
}

// ------------------------------------------------------------ history (events)

/** eth_getLogs over a range in 100-block windows: the public Monad RPC refuses wider ranges. */
async function scan<T>(from: bigint, fetch: (fromBlock: bigint, toBlock: bigint) => Promise<T[]>): Promise<T[]> {
  const latest = await publicClient.getBlockNumber();
  const out: T[] = [];
  for (let start = from; start <= latest; start += 100n) {
    const end = start + 99n < latest ? start + 99n : latest;
    out.push(...(await fetch(start, end)));
  }
  return out;
}

export async function linesOpened(d: Deployment) {
  const logs = await scan(BigInt(d.deployedAtBlock), (fromBlock, toBlock) =>
    publicClient.getContractEvents({ address: d.manager, abi: creditManagerAbi, eventName: "LineOpened", fromBlock, toBlock }),
  );
  return logs.map((l) => ({ ...(l.args as { borrower: Address; line: Address; deposit: bigint; principal: bigint }), block: l.blockNumber, tx: l.transactionHash }));
}

export async function lineEvents(d: Deployment, line: Address) {
  const logs = await scan(BigInt(d.deployedAtBlock), (fromBlock, toBlock) =>
    publicClient.getContractEvents({ address: line, abi: creditLineAbi, fromBlock, toBlock }),
  );
  return logs.map((l) => ({ name: l.eventName, args: l.args as Record<string, unknown>, block: l.blockNumber, tx: l.transactionHash }));
}

export async function curatorProposals(d: Deployment) {
  const logs = await scan(BigInt(d.deployedAtBlock), (fromBlock, toBlock) =>
    publicClient.getContractEvents({ address: d.curator, abi: riskCuratorAbi, fromBlock, toBlock }),
  );
  const queued = new Map<Hex, { id: Hex; target: Address; data: Hex; validAt: bigint; status: "pending" | "executed" | "revoked" }>();
  const tightened: { target: Address; data: Hex; block: bigint }[] = [];
  for (const l of logs) {
    const a = l.args as Record<string, unknown>;
    if (l.eventName === "Queued") queued.set(a.id as Hex, { id: a.id as Hex, target: a.target as Address, data: a.data as Hex, validAt: a.validAt as bigint, status: "pending" });
    if (l.eventName === "Executed") { const q = queued.get(a.id as Hex); if (q) q.status = "executed"; }
    if (l.eventName === "Revoked") { const q = queued.get(a.id as Hex); if (q) q.status = "revoked"; }
    if (l.eventName === "Tightened") tightened.push({ target: a.target as Address, data: a.data as Hex, block: l.blockNumber });
  }
  return { proposals: [...queued.values()], tightened };
}
