"""Build and publish deterministic score epochs.

One leaf per scored Perpl account, encoded exactly as `ScoreOracle.leafHash`:
keccak256(keccak256(abi.encode(chainId, oracle, epoch, perplAccount, features, limit, aprBps))).
Features are the integer form of the backtest's inputs (scorer/rules.py), so every leaf satisfies
`ScoreRules` onchain and no leaf can be used to reject the root. The tree is OpenZeppelin's:
sorted-pair keccak, an odd node paired with itself.

Usage:
  python -m scorer.epoch 1 --chain-id 10143 --oracle 0x... [--cutoff-block N] [--propose]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from Crypto.Hash import keccak

from scorer import rules

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE / "data"))
import backtest  # noqa: E402


def keccak256(data: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=data).digest()


def _word(value: int) -> bytes:
    return (value % (1 << 256)).to_bytes(32, "big")


def leaf_hash(chain_id: int, oracle: str, epoch: int, account: int, f: dict, limit: int, apr: int) -> bytes:
    words = [
        chain_id, int(oracle, 16), epoch, account,
        f["activeDays"], f["closes"], f["pnlExtMicro"], f["avgLevBps"], f["liqHist"], f["washShareBps"],
        int(f["washPair"]), f["maxDepositMicro"], limit, apr,
    ]
    return keccak256(keccak256(b"".join(_word(x) for x in words)))


def _pair(a: bytes, b: bytes) -> bytes:
    return keccak256(a + b if a <= b else b + a)


def tree(leaves: list[bytes]) -> tuple[bytes, list[list[str]]]:
    levels = [leaves]
    while len(levels[-1]) > 1:
        level = levels[-1]
        levels.append([_pair(level[i], level[i + 1] if i + 1 < len(level) else level[i]) for i in range(0, len(level), 2)])
    proofs = []
    for i in range(len(leaves)):
        proof, idx = [], i
        for level in levels[:-1]:
            sib = idx ^ 1
            proof.append("0x" + (level[sib] if sib < len(level) else level[idx]).hex())
            idx //= 2
        proofs.append(proof)
    return levels[-1][0], proofs


def scored_rows(cutoff_block: int) -> list[dict]:
    """The backtest's own features and float verdict (`ml_approve`) for every account at the cutoff."""
    tables = backtest.build_tables(backtest.block_time())
    cutoff_ts = float(backtest.block_time()([cutoff_block])[0])
    return backtest.score_margin_line(backtest.features(tables, cutoff_ts)).sort("accountId").to_dicts()


def build_epoch(epoch: int, chain_id: int, oracle: str, cutoff_block: int | None = None) -> dict:
    cutoff = cutoff_block or backtest.END_BLOCK
    leaves, flips = [], 0
    for row in scored_rows(cutoff):
        f = rules.quantize(row)
        if rules.eligible(f) and not row["ml_approve"]:
            raise SystemExit(f"account {row['accountId']}: integer rule more permissive than the backtest")
        flips += bool(row["ml_approve"]) and not rules.eligible(f)
        leaves.append({"perplAccount": int(row["accountId"]), "features": f, "limit": rules.limit_for(f),
                       "aprBps": rules.apr_for(f)})
    hashes = [leaf_hash(chain_id, oracle, epoch, x["perplAccount"], x["features"], x["limit"], x["aprBps"]) for x in leaves]
    root, proofs = tree(hashes)
    for item, h, proof in zip(leaves, hashes, proofs):
        item["leaf"] = "0x" + h.hex()
        item["proof"] = proof
    return {
        "epoch": epoch, "chainId": chain_id, "oracle": oracle, "cutoffBlock": cutoff, "root": "0x" + root.hex(),
        "eligible": sum(1 for x in leaves if x["limit"]), "roundingDenials": flips, "leaves": leaves,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("epoch", type=int)
    ap.add_argument("--chain-id", type=int, required=True)
    ap.add_argument("--oracle", required=True)
    ap.add_argument("--cutoff-block", type=int)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--propose", action="store_true", help="send ScoreOracle.propose (local fork by default)")
    ap.add_argument("--bond", default="0", help="publisher bond in wei")
    ap.add_argument("--rpc-url", default="http://127.0.0.1:8547")
    ap.add_argument("--private-key-env", default="SCORER_PRIVATE_KEY")
    args = ap.parse_args()
    result = build_epoch(args.epoch, args.chain_id, args.oracle, args.cutoff_block)
    out = args.out or HERE / ".agent-work" / "epochs" / f"{args.chain_id}-{args.oracle.lower()}-{args.epoch}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if args.propose:
        key = os.environ.get(args.private_key_env)
        if not key:
            raise SystemExit(f"{args.private_key_env} is required for --propose")
        cast = os.environ.get("CAST", str(Path.home() / ".foundry/bin/cast"))
        subprocess.check_call([
            cast, "send", args.oracle, "propose(uint256,bytes32,uint256,string)", str(args.epoch), result["root"],
            str(result["cutoffBlock"]), out.name, "--value", args.bond, "--rpc-url", args.rpc_url, "--private-key", key,
        ])
    print(json.dumps({k: result[k] for k in ("epoch", "root", "eligible", "roundingDenials")} | {"leaves": len(result["leaves"]), "out": str(out)}))


if __name__ == "__main__":
    main()
