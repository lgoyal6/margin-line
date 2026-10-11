// Chain access for the app: the deployment record, a read client, and wallet clients.
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const RPC_URL = import.meta.env.VITE_RPC_URL ?? "http://127.0.0.1:8547";

export type Deployment = {
  chainId: number;
  exchange: Address;
  ausd: Address;
  identity: Address;
  historyLinks: Address;
  marketFactory: Address;
  riskLens: Address;
  pool: Address;
  seniorVault: Address;
  juniorVault: Address;
  guard: Address;
  manager: Address;
  lineImplementation: Address;
  breaker: Address;
  curator: Address;
  scoreOracle: Address;
  deployedAtBlock: number;
  rpId: string;
};

export const BTC_PERP = 16n; // Perpl testnet BTC market

export const isLocalFork = () => RPC_URL.includes("127.0.0.1") || RPC_URL.includes("localhost");

let deploymentPromise: Promise<Deployment> | undefined;
export function loadDeployment(): Promise<Deployment> {
  deploymentPromise ??= fetch("/deployments/local-fork.json").then((r) => {
    if (!r.ok) throw new Error("No deployment record. Run app/scripts/local-chain.sh first.");
    return r.json() as Promise<Deployment>;
  });
  return deploymentPromise;
}

export const chain = defineChain({
  id: 10143,
  name: isLocalFork() ? "Local fork of Monad testnet" : "Monad testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const publicClient: PublicClient = createPublicClient({ chain, transport: http(RPC_URL) });

export function walletFor(privateKey: Hex) {
  return createWalletClient({ account: privateKeyToAccount(privateKey), chain, transport: http(RPC_URL) });
}

/** A wallet client that sends as `address` on the local fork, without its key (anvil impersonation). */
async function impersonated(address: Address) {
  await publicClient.request({ method: "anvil_impersonateAccount" as never, params: [address] as never });
  return createWalletClient({ account: address, chain, transport: http(RPC_URL) });
}

export async function sendAs(address: Address, tx: Parameters<Awaited<ReturnType<typeof impersonated>>["writeContract"]>[0]) {
  // Simulate first so a refusal surfaces with the contract's own reason instead of a mined revert.
  await publicClient.simulateContract({ ...(tx as object), account: address } as never);
  const client = await impersonated(address);
  try {
    return (await wait(await client.writeContract(tx as never))).transactionHash;
  } finally {
    await publicClient.request({ method: "anvil_stopImpersonatingAccount" as never, params: [address] as never });
  }
}

export async function wait(hash: Hex) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`Transaction ${hash} reverted`);
  return receipt;
}
