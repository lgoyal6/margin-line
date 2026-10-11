// Margin Line monitor: reads the market every interval and raises an alert when a threshold is
// crossed, and again when it clears. Alerts are JSON lines on stdout, optionally POSTed to a webhook.
//
//   node --experimental-strip-types monitor/src/monitor.ts                 # loop every 30 s
//   node --experimental-strip-types monitor/src/monitor.ts --once          # one check, print alerts
//
// Env: RPC_URL (default the local fork), DEPLOYMENT (default deployments/local-fork.json),
//      WEBHOOK_URL (optional), STATE_FILE (default .agent-work/monitor-state.json).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, http, type Address, type PublicClient } from "viem";
import { circuitBreakerAbi, creditLineAbi, creditManagerAbi, creditPoolAbi, trancheVaultAbi } from "../../app/src/abi.ts";

export type Severity = "warn" | "critical";
export type Alert = { id: string; severity: Severity; message: string; value?: string };
export type State = { belowFreezeSince: Record<string, string>; active: Record<string, Alert> };

// Thresholds (fixed by the plan, item 8.4).
export const UTIL_WARN_BPS = 8_500n;
export const RESERVE_MIN_BPS = 100n; // 1% of lender capital
export const QUEUE_MAX_AGE_SEC = 3n * 86_400n;
export const JUNIOR_WARN_BPS = 2_200n;
export const MISSED_FREEZE_BLOCKS = 10n;
const BTC = 16n;

type Deployment = { manager: Address; pool: Address; breaker: Address; exchange: Address; seniorVault: Address; juniorVault: Address; deployedAtBlock: number };

async function lines(pub: PublicClient, d: Deployment): Promise<Address[]> {
  const latest = await pub.getBlockNumber();
  const out: Address[] = [];
  for (let from = BigInt(d.deployedAtBlock); from <= latest; from += 100n) {
    const to = from + 99n < latest ? from + 99n : latest; // the public RPC refuses wider log ranges
    const logs = await pub.getContractEvents({ address: d.manager, abi: creditManagerAbi, eventName: "LineOpened", fromBlock: from, toBlock: to });
    for (const l of logs) out.push((l.args as { line: Address }).line);
  }
  return out;
}

async function oldestQueued(pub: PublicClient, d: Deployment, vault: Address): Promise<bigint | null> {
  const [head, len] = await Promise.all([
    pub.readContract({ address: vault, abi: trancheVaultAbi, functionName: "head" }),
    pub.readContract({ address: vault, abi: trancheVaultAbi, functionName: "queueLength" }),
  ]);
  for (let i = head; i < len; i++) {
    const [, shares] = await pub.readContract({ address: vault, abi: trancheVaultAbi, functionName: "queue", args: [i] });
    if (shares === 0n) continue; // paid or cancelled
    const latest = await pub.getBlockNumber();
    for (let from = BigInt(d.deployedAtBlock); from <= latest; from += 100n) {
      const to = from + 99n < latest ? from + 99n : latest;
      const logs = await pub.getContractEvents({ address: vault, abi: trancheVaultAbi, eventName: "WithdrawalQueued", args: { id: i }, fromBlock: from, toBlock: to });
      if (logs.length) return (await pub.getBlock({ blockNumber: logs[0].blockNumber })).timestamp;
    }
  }
  return null;
}

/** One pass over the market. Pure apart from `state.belowFreezeSince`, which spans passes. */
export async function check(pub: PublicClient, d: Deployment, state: State): Promise<Alert[]> {
  const alerts: Alert[] = [];
  const [block, risk] = await Promise.all([
    pub.getBlock(),
    pub.readContract({ address: d.manager, abi: creditManagerAbi, functionName: "riskParams" }),
  ]);
  const openBps = BigInt(risk.openHealthBps);
  const freezeBps = BigInt(risk.freezeHealthBps);

  // 1 and 2: lines near or past the freeze line.
  const seen = new Set<string>();
  for (const line of await lines(pub, d)) {
    const st = await pub.readContract({ address: line, abi: creditLineAbi, functionName: "state" });
    if (Number(st) !== 1) continue; // only Active lines can still be frozen
    const h = await pub.readContract({ address: line, abi: creditLineAbi, functionName: "healthBps" });
    if (h < openBps) alerts.push({ id: `line-at-risk:${line}`, severity: "warn", message: `Line ${line} health ${h} bps is below the ${openBps} bps needed to add risk`, value: String(h) });
    if (h < freezeBps) {
      seen.add(line);
      const since = BigInt(state.belowFreezeSince[line] ?? block.number);
      state.belowFreezeSince[line] = String(since);
      if (block.number - since > MISSED_FREEZE_BLOCKS) {
        alerts.push({ id: `missed-freeze:${line}`, severity: "critical", message: `Line ${line} has been freezable for ${block.number - since} blocks and nobody froze it: is the keeper down?`, value: String(h) });
      }
    }
  }
  for (const l of Object.keys(state.belowFreezeSince)) if (!seen.has(l)) delete state.belowFreezeSince[l];

  // 3, 4, 7: pool shape.
  const p = { address: d.pool, abi: creditPoolAbi } as const;
  const [util, maxUtil, reserve, senior, junior, outstanding, juniorBps] = await Promise.all([
    pub.readContract({ ...p, functionName: "utilizationBps" }),
    pub.readContract({ ...p, functionName: "maxUtilizationBps" }),
    pub.readContract({ ...p, functionName: "reserve" }),
    pub.readContract({ ...p, functionName: "seniorAssets" }),
    pub.readContract({ ...p, functionName: "juniorAssets" }),
    pub.readContract({ ...p, functionName: "principalOutstanding" }),
    pub.readContract({ ...p, functionName: "juniorBps" }),
  ]);
  if (util >= BigInt(maxUtil)) alerts.push({ id: "utilization", severity: "critical", message: `Pool is lent out to its ${maxUtil} bps cap: lenders can only exit through the queue`, value: String(util) });
  else if (util > UTIL_WARN_BPS) alerts.push({ id: "utilization", severity: "warn", message: `Pool utilization ${util} bps is above ${UTIL_WARN_BPS} bps`, value: String(util) });
  if (outstanding > 0n && reserve * 10_000n < (senior + junior) * RESERVE_MIN_BPS) {
    alerts.push({ id: "reserve-thin", severity: "warn", message: `Reserve ${reserve} is under 1% of lender capital while ${outstanding} is lent out`, value: String(reserve) });
  }
  if (juniorBps < JUNIOR_WARN_BPS) alerts.push({ id: "junior-thin", severity: "warn", message: `Junior is ${juniorBps} bps of the pool, close to the 2000 bps floor`, value: String(juniorBps) });

  // 5: withdrawal queue age.
  for (const [name, vault] of [["senior", d.seniorVault], ["junior", d.juniorVault]] as const) {
    const ts = await oldestQueued(pub, d, vault);
    if (ts !== null && block.timestamp - ts > QUEUE_MAX_AGE_SEC) {
      alerts.push({ id: `queue-stuck:${name}`, severity: "warn", message: `Oldest ${name} withdrawal request has waited ${(block.timestamp - ts) / 3_600n} hours`, value: String(block.timestamp - ts) });
    }
  }

  // 6: circuit breaker.
  const [g, m] = await Promise.all([
    pub.readContract({ address: d.breaker, abi: circuitBreakerAbi, functionName: "globalStatus" }),
    pub.readContract({ address: d.breaker, abi: circuitBreakerAbi, functionName: "marketStatus", args: [d.exchange, BTC] }),
  ]);
  const reasons = ["None", "Paused", "VenuePaused", "Depeg", "PegStale", "InsuranceThin"];
  if (Number(g) !== 0) alerts.push({ id: "breaker", severity: "critical", message: `Circuit breaker: ${reasons[Number(g)]}. New risk is blocked.` });
  else if (Number(m) !== 0) alerts.push({ id: "breaker", severity: "critical", message: `BTC market blocked: ${reasons[Number(m)]}. New BTC risk is blocked.` });
  return alerts;
}

/** Emit only changes: a new alert fires once, and clears once when it goes away. */
export function diff(state: State, alerts: Alert[]): { fired: Alert[]; cleared: Alert[] } {
  const now = Object.fromEntries(alerts.map((a) => [a.id, a]));
  const fired = alerts.filter((a) => !state.active[a.id] || state.active[a.id].severity !== a.severity);
  const cleared = Object.values(state.active).filter((a) => !now[a.id]);
  state.active = now;
  return { fired, cleared };
}

async function main() {
  const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8547";
  const d = JSON.parse(readFileSync(process.env.DEPLOYMENT ?? "deployments/local-fork.json", "utf8")) as Deployment;
  const stateFile = process.env.STATE_FILE ?? ".agent-work/monitor-state.json";
  const pub = createPublicClient({ transport: http(rpc) }) as PublicClient;
  const state: State = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, "utf8")) : { belowFreezeSince: {}, active: {} };
  const once = process.argv.includes("--once");
  const emit = async (event: Record<string, unknown>) => {
    const line = JSON.stringify({ ts: new Date().toISOString(), ...event });
    console.log(line);
    if (process.env.WEBHOOK_URL) await fetch(process.env.WEBHOOK_URL, { method: "POST", headers: { "content-type": "application/json" }, body: line }).catch(() => {});
  };
  do {
    try {
      const { fired, cleared } = diff(state, await check(pub, d, state));
      for (const a of fired) await emit({ event: "alert", ...a });
      for (const a of cleared) await emit({ event: "cleared", id: a.id });
    } catch (e) {
      await emit({ event: "monitor-error", severity: "critical", message: (e as Error).message.split("\n")[0] });
    }
    writeFileSync(stateFile, JSON.stringify(state, null, 2));
    if (!once) await new Promise((r) => setTimeout(r, 30_000));
  } while (!once);
}

if (import.meta.url === `file://${process.argv[1]}`) await main();

