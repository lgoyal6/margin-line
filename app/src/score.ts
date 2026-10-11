// Score epochs published by scorer/epoch.py, and their onchain check against the ScoreOracle.
import type { Address, Hex } from "viem";
import { scoreOracleAbi } from "./abi";
import { isLocalFork, publicClient, type Deployment } from "./chain";

export type ScoreFeatures = {
  activeDays: number; closes: number; pnlExtMicro: number; avgLevBps: number; liqHist: number;
  washShareBps: number; washPair: boolean; maxDepositMicro: number;
};
export type ScoreLeaf = { perplAccount: number; features: ScoreFeatures; limit: number; aprBps: number; proof: Hex[]; leaf: Hex };
export type ScoreEpoch = {
  epoch: number; chainId: number; oracle: Address; cutoffBlock: number; root: Hex; eligible: number; leaves: ScoreLeaf[];
};

export async function loadEpoch(): Promise<ScoreEpoch | null> {
  const r = await fetch(isLocalFork() ? "/epochs/latest.json" : "/epochs/latest-testnet.json");
  return r.ok ? ((await r.json()) as ScoreEpoch) : null;
}

export async function oracleStatus(d: Deployment, epoch: ScoreEpoch) {
  const o = { address: d.scoreOracle, abi: scoreOracleAbi } as const;
  const [root, finalized, fresh] = await Promise.all([
    publicClient.readContract({ ...o, functionName: "rootFor", args: [BigInt(epoch.epoch)] }),
    publicClient.readContract({ ...o, functionName: "isFinalized", args: [BigInt(epoch.epoch)] }),
    publicClient.readContract({ ...o, functionName: "epochIsFresh", args: [BigInt(epoch.epoch)] }),
  ]);
  return { root, finalized, fresh, matches: root.toLowerCase() === epoch.root.toLowerCase() && epoch.oracle.toLowerCase() === d.scoreOracle.toLowerCase() };
}

/** Asks the oracle contract itself whether this leaf is in the posted root. */
export async function verifyOnchain(d: Deployment, epoch: ScoreEpoch, leaf: ScoreLeaf): Promise<boolean> {
  const f = leaf.features;
  return publicClient.readContract({
    address: d.scoreOracle, abi: scoreOracleAbi, functionName: "verifyLeaf",
    args: [
      BigInt(epoch.epoch), BigInt(leaf.perplAccount),
      {
        activeDays: f.activeDays, closes: f.closes, pnlExtMicro: BigInt(f.pnlExtMicro), avgLevBps: f.avgLevBps,
        liqHist: f.liqHist, washShareBps: f.washShareBps, washPair: f.washPair, maxDepositMicro: BigInt(f.maxDepositMicro),
      },
      BigInt(leaf.limit), BigInt(leaf.aprBps), leaf.proof,
    ],
  });
}

/** Each rule in plain words, with the trader's number and whether it passed. */
export function explain(f: ScoreFeatures) {
  return [
    { rule: "Traded on at least 3 different days", value: `${f.activeDays} days`, ok: f.activeDays >= 3 },
    { rule: "Closed at least 10 trades", value: `${f.closes} closes`, ok: f.closes >= 10 },
    { rule: "Never liquidated", value: f.liqHist === 0 ? "never" : `${f.liqHist} times`, ok: f.liqHist === 0 },
    { rule: "Made money against other traders (wash trades removed)", value: `$${(f.pnlExtMicro / 1e6).toFixed(2)}`, ok: f.pnlExtMicro > 0 },
    { rule: "Average leverage of 5x or less", value: `${(f.avgLevBps / 1e4).toFixed(2)}x`, ok: f.avgLevBps <= 50_000 },
    { rule: "Not trading mostly inside a group of linked accounts", value: `${(f.washShareBps / 100).toFixed(0)}% inside`, ok: !f.washPair },
  ];
}
