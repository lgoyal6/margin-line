// Phase 8.4 exit test: every alert fires from a deliberate failure on the local fork.
//
// A clean market must raise no alert. Then each drill breaks one thing, runs the monitor's check,
// and requires that exact alert. Every drill runs inside an anvil snapshot and is reverted after,
// so drills cannot leak into each other. Local fork only.
//
// Run after app/scripts/local-chain.sh (and fork-mark.sh):
//   node --experimental-strip-types monitor/drills/drills.ts
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import type { PublicClient } from "viem";
import { check, type Alert, type State } from "../src/monitor.ts";
import {
  addr, asAccount, curatorAbi, d, erc20, fund, managerAbi, openBorrower, pub, send, vaultAbi, wallet,
} from "../../e2e/src/forkkit.ts";

const results: Record<string, unknown> = {};
const fresh = (): State => ({ belowFreezeSince: {}, active: {} });
const run = (s: State) => check(pub as unknown as PublicClient, d, s);
const rpcCall = (method: string, params: unknown[] = []) => pub.request({ method: method as never, params: params as never });

async function drill(name: string, expectPrefix: string, act: (s: State) => Promise<void>) {
  const snap = (await rpcCall("evm_snapshot")) as string;
  try {
    const s = fresh();
    await act(s);
    const alerts: Alert[] = await run(s);
    const hit = alerts.find((a) => a.id.startsWith(expectPrefix));
    results[name] = { fired: !!hit, alert: hit ?? null, all: alerts.map((a) => a.id) };
    console.log(`${hit ? "ok  " : "FAIL"} ${name}: ${hit ? `${hit.severity} ${hit.message}` : `no ${expectPrefix} alert (got ${alerts.map((a) => a.id).join(", ") || "none"})`}`);
  } finally {
    await rpcCall("evm_revert", [snap]);
  }
}

const owner = (await pub.readContract({ address: d.curator, abi: curatorAbi, functionName: "owner" }));
const lev = await pub.readContract({ address: d.manager, abi: managerAbi, functionName: "maxLeverageOnDepositBps" });
const tighten = (freeze: number, open: number, sweep: number) =>
  asAccount(owner, { address: d.curator, abi: curatorAbi, functionName: "tightenRisk", args: [[freeze, open, sweep], lev] });

// Baseline: a fresh market raises nothing.
{
  const alerts = await run(fresh());
  results.baseline = alerts.map((a) => a.id);
  console.log(`${alerts.length ? "FAIL" : "ok  "} baseline: ${alerts.length ? alerts.map((a) => a.id).join(", ") : "no alerts on a healthy market"}`);
}

// 1. A line drops below the health needed to add risk (curator raises the bar above it).
await drill("1 line at risk", "line-at-risk:", async () => {
  await openBorrower(1, 1_000_000_000n, 2_000_000_000n); // health 150%
  await tighten(11_000, 16_000, 12_500);
});

// 2. A line is freezable and nobody freezes it for more than 10 blocks (no keeper running).
await drill("2 missed freeze", "missed-freeze:", async (s) => {
  await openBorrower(1, 1_000_000_000n, 2_000_000_000n);
  await tighten(16_000, 17_000, 16_500); // freeze at 160% > 150%; sweep must sit above freeze
  await run(s); // first sighting
  await rpcCall("anvil_mine", ["0xb"]); // 11 blocks later
});

// 3. Utilization above 85%: four lines borrow $22,000 each from a $100,000 pool.
await drill("3 utilization", "utilization", async () => {
  for (const i of [1, 2, 3, 6]) await openBorrower(i, 7_400_000_000n, 22_000_000_000n);
});

// 4. Money is lent out while the reserve is under 1% of lender capital.
await drill("4 reserve thin", "reserve-thin", async () => {
  await openBorrower(1, 1_000_000_000n, 2_000_000_000n);
});

// 5. A withdrawal request has waited more than 3 days.
await drill("5 queue stuck", "queue-stuck:junior", async () => {
  await fund(addr(5), 1_000_000_000n);
  await send(wallet(5), { address: d.ausd, abi: erc20, functionName: "approve", args: [d.juniorVault, 1_000_000_000n] });
  await send(wallet(5), { address: d.juniorVault, abi: vaultAbi, functionName: "deposit", args: [1_000_000_000n, addr(5)] });
  const shares = await pub.readContract({ address: d.juniorVault, abi: vaultAbi, functionName: "balanceOf", args: [addr(5)] });
  await send(wallet(5), { address: d.juniorVault, abi: vaultAbi, functionName: "requestRedeem", args: [shares] });
  await rpcCall("evm_increaseTime", [3 * 86_400 + 60]);
  await rpcCall("evm_mine");
});

// 6. The guardian pauses the market. Also exercises the CLI's JSON-line output.
await drill("6 breaker", "breaker", async () => {
  const guardian = await pub.readContract({ address: d.curator, abi: [{ type: "function", name: "guardian", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] }] as const, functionName: "guardian" });
  await asAccount(guardian, { address: d.curator, abi: [{ type: "function", name: "pause", stateMutability: "nonpayable", inputs: [], outputs: [] }] as const, functionName: "pause", args: [] });
  const cli = execFileSync("node", ["--experimental-strip-types", "--no-warnings", "monitor/src/monitor.ts", "--once"], {
    env: { ...process.env, STATE_FILE: "/tmp/margin-line-monitor-drill-state.json" }, encoding: "utf8",
  });
  results.cliOutput = cli.trim().split("\n");
});

// 7. Junior thins toward its floor: a senior deposit takes junior from 30% to about 21%.
await drill("7 junior thin", "junior-thin", async () => {
  await fund(addr(5), 42_000_000_000n);
  await send(wallet(5), { address: d.ausd, abi: erc20, functionName: "approve", args: [d.seniorVault, 42_000_000_000n] });
  await send(wallet(5), { address: d.seniorVault, abi: vaultAbi, functionName: "deposit", args: [42_000_000_000n, addr(5)] });
});

mkdirSync("monitor/drills/evidence", { recursive: true });
writeFileSync("monitor/drills/evidence/drills.json", JSON.stringify(results, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
const drills = Object.entries(results).filter(([k]) => /^\d/.test(k)) as [string, { fired: boolean }][];
const ok = drills.every(([, r]) => r.fired) && (results.baseline as string[]).length === 0;
console.log(ok ? `monitor drills: PASS (${drills.length}/7 alerts fired, clean baseline)` : "monitor drills: FAIL");
if (!ok) process.exitCode = 1;
