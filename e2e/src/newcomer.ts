// Phase 7 exit test: a newcomer completes borrow, trade and sweep unaided, through the UI only.
//
// A real browser with a virtual passkey authenticator (CTAP2 with PRF, as in run.ts) drives the app
// against the local fork. The script only clicks visible buttons and types into visible fields,
// then checks the outcome directly onchain. Screenshots go to e2e/evidence/newcomer/.
//
// Run: app/scripts/local-chain.sh, then `npm --prefix app run dev -- --port 5180`, then
//      node --experimental-strip-types e2e/src/newcomer.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { chromium, type Page } from "playwright";
import { createPublicClient, http, parseAbi, type Address } from "viem";

const base = process.env.APP_URL ?? "http://localhost:5180"; // WebAuthn needs a hostname, not an IP
const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8547";
const out = "e2e/evidence/newcomer";
mkdirSync(out, { recursive: true });
const dep = JSON.parse(readFileSync("deployments/local-fork.json", "utf8"));
const pub = createPublicClient({ transport: http(rpc) });
const log: Record<string, unknown>[] = [];
let shot = 0;

async function snap(page: Page, name: string) {
  await page.screenshot({ path: `${out}/${String(++shot).padStart(2, "0")}-${name}.png`, fullPage: true });
}

/** Click a button by its visible label, wait for the app to finish, and fail on any error it shows. */
async function act(page: Page, label: string, scope = page.locator("body")) {
  const t0 = Date.now();
  const errorsBefore = await page.locator(".action-error").count();
  await scope.getByRole("button", { name: label, exact: true }).click();
  await page.waitForFunction(() => ![...document.querySelectorAll("button")].some((b) => b.textContent === "Working..."), null, { timeout: 180_000 });
  await page.waitForTimeout(1_500); // let the page reload its data
  const errors = await page.locator(".action-error").allTextContents();
  if (errors.length > errorsBefore) throw new Error(`"${label}" failed: ${errors.join(" | ")}`);
  log.push({ step: label, ms: Date.now() - t0 });
  console.log(`ok  ${label} (${Date.now() - t0} ms)`);
}

async function waitText(page: Page, text: string | RegExp) {
  await page.getByText(text).first().waitFor({ timeout: 120_000 });
}

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1200, height: 900 } });
const page = await context.newPage();
const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable");
await cdp.send("WebAuthn.addVirtualAuthenticator", {
  options: {
    protocol: "ctap2", ctap2Version: "ctap2_1", transport: "internal", hasResidentKey: true,
    hasUserVerification: true, isUserVerified: true, hasPrf: true, automaticPresenceSimulation: true,
  },
});

try {
  await page.goto(`${base}/trade`);
  await waitText(page, "Your account is a passkey");
  await snap(page, "start");

  // 1. Account: passkey only, then test funds (fork only) and onchain registration.
  await act(page, "Create account with a passkey");
  await waitText(page, "Wallet");
  await act(page, "Get test funds (local fork)");
  await waitText(page, "$5,000.00");
  await act(page, "Register passkey onchain");
  await waitText(page, "Registered");
  await snap(page, "account");
  const user = (await page.evaluate(() => JSON.parse(sessionStorage.getItem("margin-line-session")!).address)) as Address;

  // 2. Score check: an approved trader from the published list, verified onchain.
  await page.getByRole("button", { name: "Try an approved trader" }).click();
  await act(page, "Check");
  await waitText(page, "Verified onchain");
  await snap(page, "score");

  // 3. Credit: labeled demo approval (fork only), then open a line with the default 500 + 1,000.
  await act(page, "Approve this wallet for $2,000 (demo)");
  await waitText(page, "$2,000");
  await act(page, "Open credit line");
  await waitText(page, /Active line/);
  await snap(page, "line-open");

  // 3b. Session key: grant one with the passkey, see its budget, revoke it.
  await act(page, "Grant session key with passkey");
  await waitText(page, "Order budget left");
  await act(page, "Revoke session key");
  await page.getByText("Order budget left").waitFor({ state: "detached", timeout: 60_000 });

  // 4. Trade: open a $500 long at 2x, then close it.
  await act(page, "Open long");
  await waitText(page, /^Long \$/);
  await snap(page, "long-open");
  await act(page, "Close position");
  await page.getByText("No position").first().waitFor({ timeout: 120_000 });

  // 5. Sweep: take out the maximum the line allows, approved by the passkey.
  const ausdBefore = await pub.readContract({ address: dep.ausd, abi: parseAbi(["function balanceOf(address) view returns (uint256)"]), functionName: "balanceOf", args: [user] });
  await act(page, "Withdraw profit with passkey");
  await snap(page, "swept");
  const ausdAfterSweep = await pub.readContract({ address: dep.ausd, abi: parseAbi(["function balanceOf(address) view returns (uint256)"]), functionName: "balanceOf", args: [user] });

  // 6. Close the line, approved by the passkey: lenders are repaid, the rest returns to the trader.
  const line = (await pub.readContract({ address: dep.manager, abi: parseAbi(["function activeLine(address) view returns (address)"]), functionName: "activeLine", args: [user] })) as Address;
  await act(page, "Close line with passkey");
  await waitText(page, "Open a credit line");
  await snap(page, "line-closed");

  // 7. Lend: deposit to the junior tranche.
  await page.goto(`${base}/lend`);
  await waitText(page, "Your shares are worth");
  const junior = page.locator(".tranche-card.junior");
  await act(page, "Deposit", junior);
  await snap(page, "lent");

  // Onchain checks.
  const lineAbi = parseAbi(["function state() view returns (uint8)", "function principal() view returns (uint256)"]);
  const state = await pub.readContract({ address: line, abi: lineAbi, functionName: "state" });
  const principalLeft = await pub.readContract({ address: line, abi: lineAbi, functionName: "principal" });
  const poolAbi = parseAbi(["function principalOf(address) view returns (uint256)", "function totalLosses() view returns (uint256)", "function totalInterestEarned() view returns (uint256)"]);
  const [owed, losses, interest] = await Promise.all([
    pub.readContract({ address: dep.pool, abi: poolAbi, functionName: "principalOf", args: [line] }),
    pub.readContract({ address: dep.pool, abi: poolAbi, functionName: "totalLosses" }),
    pub.readContract({ address: dep.pool, abi: poolAbi, functionName: "totalInterestEarned" }),
  ]);
  const juniorShares = await pub.readContract({ address: dep.juniorVault, abi: parseAbi(["function balanceOf(address) view returns (uint256)"]), functionName: "balanceOf", args: [user] });
  const checks = {
    swept: ausdAfterSweep > ausdBefore,
    sweptAmount: (ausdAfterSweep - ausdBefore).toString(),
    lineClosed: state === 3,
    principalRepaid: principalLeft === 0n && owed === 0n,
    poolLosses: losses.toString(),
    interestPaid: interest.toString(),
    lentToJunior: juniorShares > 0n,
  };
  writeFileSync(`${out}/result.json`, JSON.stringify({ user, line, steps: log, checks }, null, 2) + "\n");
  console.log(JSON.stringify(checks, null, 2));
  if (!checks.swept || !checks.lineClosed || !checks.principalRepaid || losses !== 0n || !checks.lentToJunior) {
    throw new Error("onchain checks failed");
  }
  console.log("newcomer exit test: PASS");
} catch (e) {
  await snap(page, "failure").catch(() => {});
  console.error((e as Error).message);
  process.exitCode = 1;
} finally {
  await browser.close();
}
