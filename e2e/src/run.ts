// End-to-end passkey onboarding on Monad testnet, driven through a real browser WebAuthn stack.
//
// 1. Headless Chromium with a virtual platform authenticator (user verification + PRF), the same
//    capabilities as Face ID / Touch ID on iCloud Keychain.
// 2. Mera creates the passkey and the user's wallet is derived from its PRF output. No seed phrase,
//    no extension, no custody backend.
// 3. The passkey's P-256 key is registered onchain; the user opens a credit line.
// 4. A profit sweep and a line close are each approved by a fresh browser WebAuthn assertion and
//    verified onchain by IdentityRegistry through Monad's P-256 precompile.
// 5. Refusal beat: the same assertion replayed for a larger sweep is rejected.
//
// Env: none required. Reads deployments/monad-testnet.json and the testnet deployer key, which funds
// the new wallet with a little MON and AUSD and acts as underwriter.

import { createServer } from "node:http";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, extname } from "node:path";
import { chromium } from "playwright";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  parseAbi,
  toBytes,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = resolve(import.meta.dirname, "..", "..");
const PORT = 5199;
const RPC = process.env.RPC_URL ?? "https://testnet-rpc.monad.xyz";
const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

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

const identityAbi = parseAbi([
  "function registerFirstPasskey(bytes32 qx, bytes32 qy) returns (bytes32)",
  "function keyIdOf(bytes32 qx, bytes32 qy) pure returns (bytes32)",
  "function challengeFor(address user, address consumer, bytes32 action) view returns (bytes32)",
  "error InvalidAssertion()",
]);
const managerAbi = parseAbi([
  "function approve(address borrower, uint128 limit, uint16 aprBps, uint40 expiry)",
  "function openLine(uint256 deposit, uint256 principal) returns (address)",
  "function activeLine(address) view returns (address)",
]);
const erc20Abi = parseAbi([
  "function approve(address, uint256) returns (bool)",
  "function transfer(address, uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);
const proofType =
  "(bytes32 keyId, (bytes32 r, bytes32 s, uint256 challengeIndex, uint256 typeIndex, bytes authenticatorData, string clientDataJSON) auth)";
const lineAbi = parseAbi([
  `function sweep(uint256 amount, ${proofType} proof)`,
  `function close(${proofType} proof)`,
  "function state() view returns (uint8)",
  "function healthBps() view returns (uint256)",
  "error InvalidAssertion()",
]);

const evidence: Record<string, unknown> = { chainId: 10143, deployment: dep };
const step = (name: string, data: Record<string, unknown>) => {
  evidence[name] = data;
  console.log(JSON.stringify({ step: name, ...data }, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
};

function serve() {
  const types: Record<string, string> = { ".html": "text/html", ".js": "text/javascript" };
  return createServer((req, res) => {
    const path = req.url === "/" ? "/index.html" : req.url!;
    if (path === "/index.html") {
      res.writeHead(200, { "content-type": "text/html" });
      res.end('<!doctype html><meta charset="utf-8"><title>Margin Line e2e</title><script type="module" src="/onboard.js"></script>');
      return;
    }
    try {
      const body = readFileSync(resolve(ROOT, "e2e/public", "." + path));
      res.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  }).listen(PORT);
}

/** P-256 public key from a SubjectPublicKeyInfo: the last 65 bytes are 0x04 || x || y. */
function spkiToXY(spki: Hex): [Hex, Hex] {
  const b = spki.slice(2);
  const point = b.slice(b.length - 130);
  if (!point.startsWith("04")) throw new Error("unexpected public key encoding");
  return [`0x${point.slice(2, 66)}`, `0x${point.slice(66)}`];
}

/** DER ECDSA signature to (r, s) with s in low form. */
function derToRS(der: Hex): [Hex, Hex] {
  const b = toBytes(der);
  let i = 2;
  const read = () => {
    if (b[i++] !== 0x02) throw new Error("bad DER");
    const len = b[i++];
    const v = b.slice(i, i + len);
    i += len;
    return BigInt("0x" + [...v].map((x) => x.toString(16).padStart(2, "0")).join(""));
  };
  const r = read();
  let s = read();
  if (s > P256_N / 2n) s = P256_N - s;
  const pad = (x: bigint) => `0x${x.toString(16).padStart(64, "0")}` as Hex;
  return [pad(r), pad(s)];
}

async function main() {
  const server = serve();
  const browser = await chromium.launch({ headless: true });
  const page = await (await browser.newContext()).newPage();
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      ctap2Version: "ctap2_1",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      hasPrf: true,
      automaticPresenceSimulation: true,
    },
  });
  await page.goto(`http://localhost:${PORT}/`);
  await page.waitForFunction(() => typeof window.onboard === "function");

  // 1-2. Passkey-only onboarding through Mera.
  const onboard = await page.evaluate(() => window.onboard());
  const user = privateKeyToAccount(onboard.walletKey as Hex);
  const [qx, qy] = spkiToXY(onboard.spki as Hex);
  step("onboarded", { wallet: user.address, credentialId: onboard.credentialId, qx, qy, rpId: "localhost" });

  const deployer = privateKeyToAccount(deployerKey);
  const asDeployer = createWalletClient({ chain, transport: http(RPC), account: deployer });
  const asUser = createWalletClient({ chain, transport: http(RPC), account: user });
  const wait = async (hash: Hex, label: string) => {
    const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 200 });
    step(label, { hash, block: r.blockNumber, status: r.status, gasUsed: r.gasUsed });
    if (r.status !== "success") throw new Error(`${label} reverted`);
    return r;
  };

  // Fund the new wallet for gas and its first-loss deposit (testnet only).
  const funding = await wait(await asDeployer.sendTransaction({ to: user.address, value: 450_000_000_000_000_000n }), "fund_mon");
  await wait(await asDeployer.writeContract({ address: dep.ausd, abi: erc20Abi, functionName: "transfer", args: [user.address, 200_000_000n] }), "fund_ausd");
  // Monad checks a sender's gas budget against its balance as of a few blocks ago (reserve balance,
  // k = 3), so a wallet funded in the last block still looks empty. Wait it out before sending.
  while ((await pub.getBlockNumber({ cacheTime: 0 })) < funding.blockNumber + 4n) await new Promise((r) => setTimeout(r, 300));

  // 3. Register the passkey and open a line.
  await wait(await asUser.writeContract({ address: dep.identity, abi: identityAbi, functionName: "registerFirstPasskey", args: [qx, qy] }), "register_passkey");
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 86_400);
  await wait(await asDeployer.writeContract({ address: dep.manager, abi: managerAbi, functionName: "approve", args: [user.address, 100_000_000n, 1_000, Number(expiry)] }), "underwriter_approve");
  await wait(await asUser.writeContract({ address: dep.ausd, abi: erc20Abi, functionName: "approve", args: [dep.manager, 100_000_000n] }), "approve_deposit");
  await wait(await asUser.writeContract({ address: dep.manager, abi: managerAbi, functionName: "openLine", args: [100_000_000n, 100_000_000n] }), "open_line");
  const line = (await pub.readContract({ address: dep.manager, abi: managerAbi, functionName: "activeLine", args: [user.address] })) as Address;
  step("line", { line, healthBps: await pub.readContract({ address: line, abi: lineAbi, functionName: "healthBps" }) });

  const keyId = (await pub.readContract({ address: dep.identity, abi: identityAbi, functionName: "keyIdOf", args: [qx, qy] })) as Hex;
  const proveInBrowser = async (action: Hex) => {
    const challenge = (await pub.readContract({ address: dep.identity, abi: identityAbi, functionName: "challengeFor", args: [user.address, line, action] })) as Hex;
    const a = await page.evaluate(([c, id]) => window.approve(c, id), [challenge, onboard.credentialId]);
    const [r, s] = derToRS(a.signature as Hex);
    return {
      keyId,
      auth: {
        r,
        s,
        challengeIndex: BigInt(a.clientDataJSON.indexOf('"challenge":"')),
        typeIndex: BigInt(a.clientDataJSON.indexOf('"type":"webauthn.get"')),
        authenticatorData: a.authenticatorData as Hex,
        clientDataJSON: a.clientDataJSON,
      },
    };
  };

  // 4. Sweep 20 AUSD of the line's equity, approved by a fresh browser assertion.
  const amount = 20_000_000n;
  const sweepProof = await proveInBrowser(keccak256(encodeAbiParameters([{ type: "string" }, { type: "uint256" }], ["sweep", amount])));
  step("browser_assertion", { clientDataJSON: sweepProof.auth.clientDataJSON, authenticatorDataLength: (sweepProof.auth.authenticatorData.length - 2) / 2 });

  // 5. Refusal: the same assertion cannot authorize a larger sweep.
  try {
    await pub.simulateContract({ address: line, abi: lineAbi, functionName: "sweep", args: [amount * 10n, sweepProof], account: user });
    throw new Error("tampered sweep was accepted");
  } catch (e) {
    const msg = (e as Error).message;
    if (!msg.includes("InvalidAssertion")) throw e;
    step("refused_tampered_sweep", { requested: amount * 10n, approved: amount, error: "InvalidAssertion" });
  }

  const before = (await pub.readContract({ address: dep.ausd, abi: erc20Abi, functionName: "balanceOf", args: [user.address] })) as bigint;
  await wait(await asUser.writeContract({ address: line, abi: lineAbi, functionName: "sweep", args: [amount, sweepProof] }), "sweep_with_passkey");
  const after = (await pub.readContract({ address: dep.ausd, abi: erc20Abi, functionName: "balanceOf", args: [user.address] })) as bigint;
  step("swept", { received: after - before });

  // Close the line with another browser assertion.
  const closeProof = await proveInBrowser(keccak256(toBytes("close")));
  await wait(await asUser.writeContract({ address: line, abi: lineAbi, functionName: "close", args: [closeProof] }), "close_with_passkey");
  step("closed", { state: await pub.readContract({ address: line, abi: lineAbi, functionName: "state" }) });

  mkdirSync(resolve(ROOT, "e2e/evidence"), { recursive: true });
  writeFileSync(resolve(ROOT, "e2e/evidence/passkey-onboarding.json"), JSON.stringify(evidence, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
  await browser.close();
  server.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
