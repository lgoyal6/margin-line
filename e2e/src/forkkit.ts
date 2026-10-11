// Shared setup for scripts that build market state on the local fork with anvil dev keys:
// funding by impersonating Perpl, opening lines, BTC trades. Local fork only.
import { generateKeyPairSync } from "node:crypto";
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseAbi, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const rpc = "http://127.0.0.1:8547";
export const d = JSON.parse(readFileSync("deployments/local-fork.json", "utf8"));
export const chain = { id: 10143, name: "fork", nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } } as const;
export const pub = createPublicClient({ chain, transport: http(rpc) });
export const KEYS: Hex[] = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
  "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
];
export const wallet = (i: number) => createWalletClient({ account: privateKeyToAccount(KEYS[i]), chain, transport: http(rpc) });
export const addr = (i: number) => privateKeyToAccount(KEYS[i]).address;

export const erc20 = parseAbi(["function transfer(address,uint256) returns (bool)", "function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"]);
export const identityAbi = parseAbi(["function registerFirstPasskey(bytes32,bytes32) returns (bytes32)"]);
export const managerAbi = parseAbi([
  "function approve(address,uint128,uint16,uint40)", "function openLine(uint256,uint256) returns (address)",
  "function activeLine(address) view returns (address)", "function riskParams() view returns ((uint16,uint16,uint16))",
  "function maxLeverageOnDepositBps() view returns (uint16)",
]);
export const lineAbi = parseAbi([
  "function freeze()", "function unwind(uint256,uint256)", "function settleFrozen()", "function state() view returns (uint8)",
  "function healthBps() view returns (uint256)", "function debt() view returns (uint256)",
]);
export const tradeAbi = parseAbi([
  "struct O { uint256 orderDescId; uint256 perpId; uint8 orderType; uint256 orderId; uint256 pricePNS; uint256 lotLNS; uint256 expiryBlock; bool postOnly; bool fillOrKill; bool immediateOrCancel; uint256 maxMatches; uint256 leverageHdths; uint256 lastExecutionBlock; uint256 amountCNS; uint256 maxNegPnlCollatBPS; }",
  "function trade(O[] orders)",
]);
export const curatorAbi = parseAbi(["function tightenRisk((uint16,uint16,uint16),uint16)", "function owner() view returns (address)"]);
export const vaultAbi = parseAbi([
  "function deposit(uint256,address) returns (uint256)", "function requestRedeem(uint256) returns (uint256)", "function balanceOf(address) view returns (uint256)",
  "function queueLength() view returns (uint256)", "function head() view returns (uint256)", "function queue(uint256) view returns (address,uint256)",
  "function convertToAssets(uint256) view returns (uint256)", "function totalAssets() view returns (uint256)",
]);
export const poolAbi = parseAbi([
  "function principalOutstanding() view returns (uint256)", "function totalLosses() view returns (uint256)", "function utilizationBps() view returns (uint256)",
  "function idle() view returns (uint256)",
]);

export async function send(w: ReturnType<typeof wallet>, tx: Record<string, unknown>) {
  const hash = await w.writeContract(tx as never);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`reverted: ${String(tx.functionName)}`);
}

export async function asAccount(who: Address, tx: Record<string, unknown>) {
  await pub.request({ method: "anvil_impersonateAccount" as never, params: [who] as never });
  await pub.request({ method: "anvil_setBalance" as never, params: [who, "0x56BC75E2D63100000"] as never });
  const w = createWalletClient({ account: who, chain, transport: http(rpc) });
  const hash = await w.writeContract(tx as never);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`reverted as ${who}: ${String(tx.functionName)}`);
}

export async function fund(who: Address, ausd: bigint) {
  await pub.request({ method: "anvil_setBalance" as never, params: [who, "0x8AC7230489E80000"] as never });
  await asAccount(d.exchange, { address: d.ausd, abi: erc20, functionName: "transfer", args: [who, ausd] });
}

export function p256Point(): [Hex, Hex] {
  const jwk = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).publicKey.export({ format: "jwk" });
  const hex = (b64: string) => `0x${Buffer.from(b64, "base64url").toString("hex")}` as Hex;
  return [hex(jwk.x!), hex(jwk.y!)];
}

export async function openBorrower(i: number, deposit: bigint, principal: bigint): Promise<Address> {
  await fund(addr(i), deposit);
  await send(wallet(i), { address: d.identity, abi: identityAbi, functionName: "registerFirstPasskey", args: p256Point() });
  const now = (await pub.getBlock()).timestamp;
  await send(wallet(0), { address: d.manager, abi: managerAbi, functionName: "approve", args: [addr(i), principal, 1_000, Number(now) + 86_400] });
  await send(wallet(i), { address: d.ausd, abi: erc20, functionName: "approve", args: [d.manager, deposit] });
  await send(wallet(i), { address: d.manager, abi: managerAbi, functionName: "openLine", args: [deposit, principal] });
  return (await pub.readContract({ address: d.manager, abi: managerAbi, functionName: "activeLine", args: [addr(i)] })) as Address;
}

export async function longBtc(i: number, line: Address, lots: bigint) {
  const info = await pub.readContract({
    address: d.exchange,
    abi: parseAbi(["function getPerpetualInfoV2(uint256) view returns ((string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256 markPNS,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256))"]),
    functionName: "getPerpetualInfoV2", args: [16n],
  });
  const mark = (info as unknown as bigint[])[11];
  const order = { orderDescId: 0n, perpId: 16n, orderType: 0, orderId: 0n, pricePNS: (mark * 10_090n) / 10_000n, lotLNS: lots,
    expiryBlock: 0n, postOnly: false, fillOrKill: false, immediateOrCancel: true, maxMatches: 50n, leverageHdths: 300n,
    lastExecutionBlock: 0n, amountCNS: 0n, maxNegPnlCollatBPS: 10_000n };
  const hash = await wallet(i).writeContract({ address: line, abi: tradeAbi, functionName: "trade", args: [[order]], gas: 900_000n });
  if ((await pub.waitForTransactionReceipt({ hash })).status !== "success") throw new Error("setup trade reverted");
}
