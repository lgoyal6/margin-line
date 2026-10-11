"""Eligibility and local-fork approval service."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from functools import lru_cache
from pathlib import Path
import shutil

import polars as pl

DATA = Path(__file__).resolve().parents[1] / "data"
sys.path.insert(0, str(DATA))
import backtest  # noqa: E402

RULES = (
    ("active_days", "at least 3 active trading days", lambda row: row["active_days"] >= backtest.MIN_ACTIVE_DAYS),
    ("n_closes", "at least 10 completed positions", lambda row: row["n_closes"] >= backtest.MIN_CLOSES),
    ("liq_hist", "no liquidation in the observed history", lambda row: row["liq_hist"] == 0),
    ("pnl_ext", "positive external realized PnL", lambda row: row["pnl_ext"] > 0),
    ("avg_lev", "average leverage at or below 5x", lambda row: row["avg_lev"] <= backtest.MAX_AVG_LEVERAGE),
    ("wash_pair", "no reciprocal wash-trading pair", lambda row: not row["wash_pair"]),
)


@dataclass(frozen=True)
class RuleResult:
    field: str
    description: str
    passed: bool


@dataclass(frozen=True)
class Decision:
    address: str
    account_id: int | None
    eligible: bool
    limit_ausd: int
    simulated: bool
    explanation: list[RuleResult]

    def json(self) -> dict:
        value = asdict(self)
        value["explanation"] = [asdict(item) for item in self.explanation]
        return value


@lru_cache(maxsize=1)
def _history() -> tuple[pl.DataFrame, pl.DataFrame]:
    tables = backtest.build_tables(backtest.block_time())
    now = float(backtest.block_time()([backtest.END_BLOCK])[0])
    scored = backtest.score_margin_line(backtest.features(tables, now))
    accounts = pl.read_parquet(DATA / "derived/events/AccountCreated.parquet")
    return scored, accounts


def _row_for(address: str, scored: pl.DataFrame, accounts: pl.DataFrame) -> tuple[int | None, dict | None]:
    normalized = address.lower()
    matches = accounts.filter(pl.col("account").str.to_lowercase() == normalized)
    if matches.height == 0 and normalized.isdigit():
        account_id = int(normalized)
    elif matches.height:
        account_id = int(matches.sort("block").tail(1)["id"][0])
    else:
        return None, None
    rows = scored.filter(pl.col("accountId") == account_id)
    return account_id, (rows.sort("last_ts").tail(1).to_dicts()[0] if rows.height else None)


def evaluate_rules(row: dict) -> list[RuleResult]:
    return [RuleResult(field, description, bool(check(row))) for field, description, check in RULES]


def decide(address: str, *, demo: bool = False) -> Decision:
    scored, accounts = _history()
    account_id, row = _row_for(address, scored, accounts)
    if row is None:
        if not demo:
            return Decision(address, account_id, False, 0, False, [RuleResult("history", "decoded Perpl history is linked", False)])
        return Decision(address, account_id, True, 100, True, [RuleResult("history", "demo approval has no real score", False)])
    explanation = evaluate_rules(row)
    eligible = all(item.passed for item in explanation)
    limit = int(min(max(float(row["max_deposit"]), 0) * 2, 10_000)) if eligible else 0
    return Decision(address, account_id, eligible, limit, False, explanation)


def approve_local(decision: Decision, *, rpc_url: str, manager: str, private_key: str) -> str:
    if not rpc_url.startswith(("http://127.0.0.1:", "http://localhost:")):
        raise ValueError("approval writes are restricted to a local fork RPC")
    if not decision.eligible:
        raise ValueError("cannot approve an ineligible borrower")
    cast = shutil.which("cast") or str(Path.home() / ".foundry/bin/cast")
    args = [cast, "send", manager, "approve(address,uint128,uint16,uint40)", decision.address,
            str(decision.limit_ausd * 1_000_000), "800", str(int(time.time()) + 365 * 86400), "--private-key", private_key,
            "--rpc-url", rpc_url]
    return subprocess.check_output(args, text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("address")
    parser.add_argument("--demo", action="store_true", help="explicitly approve without real history")
    parser.add_argument("--approve", action="store_true")
    parser.add_argument("--rpc-url", default="http://127.0.0.1:8547")
    parser.add_argument("--manager")
    args = parser.parse_args()
    decision = decide(args.address, demo=args.demo)
    result = decision.json()
    if args.approve:
        if not args.manager:
            parser.error("--manager is required with --approve")
        result["tx"] = approve_local(decision, rpc_url=args.rpc_url, manager=args.manager,
                                       private_key=os.environ.get("UNDERWRITER_PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
