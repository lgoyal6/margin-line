"""Check a built epoch against its ScoreOracle onchain: the root matches, real leaves verify, and a
tampered leaf does not.

Usage: .agent-work/venv/bin/python -m scorer.verify_onchain <epoch.json> [--rpc-url URL] [--samples N]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path

CAST = os.environ.get("CAST", str(Path.home() / ".foundry/bin/cast"))
SIG = "verifyLeaf(uint256,uint256,(uint32,uint32,int256,uint32,uint32,uint32,bool,uint256),uint256,uint256,bytes32[])(bool)"


def cast_call(rpc: str, to: str, sig: str, *args: str) -> str:
    return subprocess.check_output([CAST, "call", to, sig, *args, "--rpc-url", rpc], text=True).strip()


def verify(rpc: str, oracle: str, epoch: int, leaf: dict, limit: int | None = None) -> bool:
    f = leaf["features"]
    feats = "({},{},{},{},{},{},{},{})".format(
        f["activeDays"], f["closes"], f["pnlExtMicro"], f["avgLevBps"], f["liqHist"], f["washShareBps"],
        str(f["washPair"]).lower(), f["maxDepositMicro"])
    out = cast_call(rpc, oracle, SIG, str(epoch), str(leaf["perplAccount"]), feats,
                    str(leaf["limit"] if limit is None else limit), str(leaf["aprBps"]), "[" + ",".join(leaf["proof"]) + "]")
    return out == "true"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("epoch_json", type=Path)
    ap.add_argument("--rpc-url", default="http://127.0.0.1:8547")
    ap.add_argument("--samples", type=int, default=5)
    args = ap.parse_args()
    e = json.loads(args.epoch_json.read_text())
    root = cast_call(args.rpc_url, e["oracle"], "rootFor(uint256)(bytes32)", str(e["epoch"]))
    finalized = cast_call(args.rpc_url, e["oracle"], "isFinalized(uint256)(bool)", str(e["epoch"]))
    eligible = [x for x in e["leaves"] if x["limit"]]
    denied = [x for x in e["leaves"] if not x["limit"]]
    picks = eligible[: args.samples] + denied[:2]
    results = {str(x["perplAccount"]): verify(args.rpc_url, e["oracle"], e["epoch"], x) for x in picks}
    tampered = verify(args.rpc_url, e["oracle"], e["epoch"], eligible[0], limit=eligible[0]["limit"] + 1)
    report = {"rootMatches": root.lower() == e["root"].lower(), "finalized": finalized == "true",
              "leavesVerified": results, "tamperedLimitVerifies": tampered}
    print(json.dumps(report, indent=2))
    if not (report["rootMatches"] and all(results.values()) and not tampered):
        raise SystemExit("onchain verification failed")


if __name__ == "__main__":
    main()
