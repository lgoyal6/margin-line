// Phase 7 checks for the lender, curator and explorer pages (items 7.6 to 7.8).
//
// Setup (direct transactions with anvil dev keys, on the local fork only) builds a realistic market:
// three large lines so utilization is high, one of them frozen by a keeper and settled, and a first
// lender already waiting in the junior withdrawal queue. Then a real browser with a passkey drives
// the Lend and Curate pages, and every figure on Explore and the stress panel is compared with a
// direct contract read.
//
// Run after app/scripts/local-chain.sh, app/scripts/fork-mark.sh and the app dev server on :5180:
//   node --experimental-strip-types e2e/src/roles.ts
import { mkdirSync, writeFileSync } from "node:fs";
import { chromium, type Page } from "playwright";
import { parseAbi, type Address } from "viem";
import { rpc, d, chain, pub, KEYS, wallet, addr, erc20, identityAbi, managerAbi, lineAbi, tradeAbi, curatorAbi, vaultAbi, poolAbi, send, asAccount, fund, p256Point, openBorrower, longBtc } from "./forkkit.ts";

const base = process.env.APP_URL ?? "http://localhost:5180";
const out = "e2e/evidence/roles";
mkdirSync(out, { recursive: true });
const checks: Record<string, unknown> = {};

async function act(page: Page, label: string, scope = page.locator("body")) {
  const before = await page.locator(".action-error").count();
  await scope.getByRole("button", { name: label, exact: true }).click();
  await page.waitForFunction(() => ![...document.querySelectorAll("button")].some((b) => b.textContent === "Working..."), null, { timeout: 180_000 });
  await page.waitForTimeout(1_500);
  const errors = await page.locator(".action-error").allTextContents();
  if (errors.length > before) throw new Error(`"${label}" failed: ${errors.join(" | ")}`);
  console.log(`ok  ${label}`);
}

/** The value text of the stat card with this label, once it has loaded. */
async function stat(page: Page, label: string, scope = page.locator("body")): Promise<string> {
  const card = scope.locator(".stat", { has: page.locator(".stat-label", { hasText: new RegExp(`^${label}$`) }) }).first();
  await card.waitFor({ timeout: 120_000 });
  return (await card.locator(".stat-value").innerText()).trim();
}
const dollars = (s: string) => Math.round(Number(s.replace(/[^0-9.\-]/g, "")) * 100);
const cents = (v: bigint) => Math.round(Number(v) / 1e4);

// ------------------------------------------------------------ setup
console.log("setup: two large lines, a fully borrowed line holding BTC, a frozen-and-settled line, a queued lender");
const lineA = await openBorrower(1, 8_400_000_000n, 25_000_000_000n);
const lineB = await openBorrower(2, 8_400_000_000n, 25_000_000_000n);
const lineC = await openBorrower(3, 1_000_000_000n, 2_000_000_000n);
await longBtc(3, lineC, 3_000n);
// D borrows the full 3x and holds about $10,000 of BTC (the per-line cap), so a 30% drop costs the pool.
const lineD = await openBorrower(6, 1_000_000_000n, 3_000_000_000n);
await longBtc(6, lineD, 12_000n);
// Make C freezable: the curator tightens thresholds (instant), a keeper freezes, unwinds and settles.
const owner = (await pub.readContract({ address: d.curator, abi: curatorAbi, functionName: "owner" })) as Address;
const lev = await pub.readContract({ address: d.manager, abi: managerAbi, functionName: "maxLeverageOnDepositBps" });
await asAccount(owner, { address: d.curator, abi: curatorAbi, functionName: "tightenRisk", args: [[25_000, 30_000, 30_000], lev] });
// Fixed gas ceilings, as the keeper uses: estimates for calls into Perpl run tight.
await send(wallet(4), { address: lineC, abi: lineAbi, functionName: "freeze", args: [], gas: 1_500_000n });
await send(wallet(4), { address: lineC, abi: lineAbi, functionName: "unwind", args: [16n, 2n ** 64n], gas: 1_500_000n });
await send(wallet(4), { address: lineC, abi: lineAbi, functionName: "settleFrozen", args: [], gas: 1_500_000n });
// A first lender queues junior shares, so the browser lender has an amount ahead of it.
await fund(addr(5), 3_000_000_000n);
await send(wallet(5), { address: d.ausd, abi: erc20, functionName: "approve", args: [d.juniorVault, 3_000_000_000n] });
await send(wallet(5), { address: d.juniorVault, abi: vaultAbi, functionName: "deposit", args: [3_000_000_000n, addr(5)] });
const firstShares = await pub.readContract({ address: d.juniorVault, abi: vaultAbi, functionName: "balanceOf", args: [addr(5)] });
await send(wallet(5), { address: d.juniorVault, abi: vaultAbi, functionName: "requestRedeem", args: [firstShares] });
checks.utilizationBps = String(await pub.readContract({ address: d.pool, abi: poolAbi, functionName: "utilizationBps" }));
checks.lineCState = await pub.readContract({ address: lineC, abi: lineAbi, functionName: "state" });

// ------------------------------------------------------------ browser
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1200, height: 900 } });
const page = await context.newPage();
const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable");
await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", ctap2Version: "ctap2_1", transport: "internal",
  hasResidentKey: true, hasUserVerification: true, isUserVerified: true, hasPrf: true, automaticPresenceSimulation: true } });

try {
  // 7.6 Lender: deposit to both tranches, queue while utilization is high, check queue position.
  await page.goto(`${base}/trade`);
  await act(page, "Create account with a passkey");
  await act(page, "Get test funds (local fork)");
  await page.goto(`${base}/lend`);
  const senior = page.locator(".tranche-card.senior");
  const junior = page.locator(".tranche-card.junior");
  await stat(page, "Your shares are worth", junior);
  await act(page, "Deposit", senior);
  await act(page, "Deposit", junior);
  await act(page, "Queue all my shares", junior);
  await page.locator(".queue-item").first().waitFor({ timeout: 60_000 });
  const queueText = await junior.locator(".queue-item").first().innerText();
  await page.screenshot({ path: `${out}/lend.png`, fullPage: true });
  const user = (await page.evaluate(() => JSON.parse(sessionStorage.getItem("margin-line-session")!).address)) as Address;
  // Contract truth: the amount queued ahead of the user's request.
  const head = await pub.readContract({ address: d.juniorVault, abi: vaultAbi, functionName: "head" });
  const len = await pub.readContract({ address: d.juniorVault, abi: vaultAbi, functionName: "queueLength" });
  let ahead = 0n;
  let mine = -1;
  for (let i = head; i < len; i++) {
    const [o, sh] = await pub.readContract({ address: d.juniorVault, abi: vaultAbi, functionName: "queue", args: [i] });
    if (o.toLowerCase() === user.toLowerCase()) { mine = Number(i); break; }
    ahead += await pub.readContract({ address: d.juniorVault, abi: vaultAbi, functionName: "convertToAssets", args: [sh] });
  }
  const shownAhead = dollars(queueText.split("with ")[1] ?? "");
  checks.lender = { queueText, requestId: mine, aheadOnchain: ahead.toString(), aheadMatches: shownAhead === cents(ahead) && queueText.includes(`#${mine}`) };
  const seniorShares = await pub.readContract({ address: d.seniorVault, abi: vaultAbi, functionName: "balanceOf", args: [user] });
  checks.lenderSeniorShares = seniorShares > 0n;

  // 7.7 Curator: tighten, refuse a loosening through the instant path, propose one, see it pending.
  await page.goto(`${base}/curate`);
  await stat(page, "Most one line can borrow");
  await page.locator("input").first().fill("20");
  await act(page, "Tighten now");
  checks.tightened = (await stat(page, "Most one line can borrow")).startsWith("20%");
  await page.locator("input").first().fill("50");
  await page.getByRole("button", { name: "Tighten now", exact: true }).click();
  await page.locator(".action-error", { hasText: "NotTightening" }).waitFor({ timeout: 60_000 });
  checks.looseningRefused = true;
  await act(page, "Propose (timelocked)");
  checks.pendingShown = (await page.locator(".queue-item").first().innerText()).includes("pending");
  // Stress panel equals a direct RiskLens call over the same open lines.
  await page.waitForFunction(() => [...document.querySelectorAll(".stat-label")].some((e) => e.textContent === "Open lines tested"), null, { timeout: 120_000 });
  await page.waitForTimeout(3_000);
  const shownLines = Number(await stat(page, "Open lines tested"));
  const shownLoss = dollars(await stat(page, "Total loss"));
  const shownJunior = dollars(await stat(page, "Paid by junior"));
  const lensAbi = parseAbi([
    "struct Shock { uint256 perpId; int256 moveBps; }",
    "struct LineResult { address line; uint256 equityNow; uint256 equityAfter; uint256 debt; uint256 principalLost; }",
    "struct Result { LineResult[] lines; uint256 totalLoss; uint256 fromReserve; uint256 fromJunior; uint256 fromSenior; uint256 seniorAfter; uint256 juniorAfter; uint256 reserveAfter; }",
    "function stress(address manager, address[] lines, Shock[] shocks) view returns (Result)",
  ]);
  const direct = await pub.readContract({ address: d.riskLens, abi: lensAbi, functionName: "stress", args: [d.manager, [lineA, lineB, lineD], [{ perpId: 16n, moveBps: -3_000n }]] });
  checks.stress = { shownLines, shownLoss, shownJunior, directLoss: direct.totalLoss.toString(), directJunior: direct.fromJunior.toString(),
    matches: shownLines === 3 && direct.totalLoss > 0n && shownLoss === cents(direct.totalLoss) && shownJunior === cents(direct.fromJunior) };
  await page.screenshot({ path: `${out}/curate.png`, fullPage: true });

  // 7.8 Explorer: every figure against a direct read.
  await page.goto(`${base}/explore`);
  await page.locator("table").waitFor({ timeout: 180_000 });
  const outstanding = await pub.readContract({ address: d.pool, abi: poolAbi, functionName: "principalOutstanding" });
  const losses = await pub.readContract({ address: d.pool, abi: poolAbi, functionName: "totalLosses" });
  const explorer = {
    linesEver: Number(await stat(page, "Lines ever opened")),
    openNow: Number(await stat(page, "Open now")),
    everFrozen: Number(await stat(page, "Ever frozen")),
    bounties: dollars(await stat(page, "Bounties paid to freezers")),
    lentOut: dollars(await stat(page, "Lent out")),
    poolLosses: dollars(await stat(page, "Pool losses")),
    rows: await page.locator("tbody tr").count(),
  };
  const bountyEvents = await pub.getContractEvents({ address: lineC, abi: parseAbi(["event BountyPaid(address indexed enforcer, uint256 amount)"]), fromBlock: BigInt(d.deployedAtBlock) });
  const bountyOnchain = bountyEvents.reduce((s, e) => s + (e.args.amount ?? 0n), 0n);
  checks.explorer = { ...explorer, matches:
    explorer.linesEver === 4 && explorer.openNow === 3 && explorer.everFrozen === 1 && explorer.rows === 4 &&
    explorer.bounties === cents(bountyOnchain) && explorer.lentOut === Math.round(Number(outstanding) / 1e6) * 100 &&
    explorer.poolLosses === cents(losses) };
  await page.screenshot({ path: `${out}/explore.png`, fullPage: true });

  writeFileSync(`${out}/result.json`, JSON.stringify(checks, null, 2) + "\n");
  console.log(JSON.stringify(checks, null, 2));
  const ok = (checks.lender as { aheadMatches: boolean }).aheadMatches && checks.lenderSeniorShares && checks.tightened &&
    checks.looseningRefused && checks.pendingShown && (checks.stress as { matches: boolean }).matches &&
    (checks.explorer as { matches: boolean }).matches && checks.lineCState === 3;
  if (!ok) throw new Error("a page figure did not match the chain");
  console.log("roles test: PASS");
} catch (e) {
  await page.screenshot({ path: `${out}/failure.png`, fullPage: true }).catch(() => {});
  writeFileSync(`${out}/result.json`, JSON.stringify(checks, null, 2) + "\n");
  console.error((e as Error).message);
  process.exitCode = 1;
} finally {
  await browser.close();
}

