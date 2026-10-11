"""Integer form of the approval rule, mirroring src/ScoreRules.sol exactly.

The Python rule in data/backtest.py works on floats; leaves carry integers. `quantize` converts
a scored row to integers, rounding every feature in the strict direction (PnL down, leverage up,
deposit down), so a leaf can never be more permissive than the float rule. The only possible
disagreement is a float-approved trader denied at the boundary, never the reverse.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "data"))
import backtest  # noqa: E402

# Thresholds come from the backtest itself, so the two rules cannot drift apart.
MIN_ACTIVE_DAYS = backtest.MIN_ACTIVE_DAYS
MIN_CLOSES = backtest.MIN_CLOSES
MAX_AVG_LEV_BPS = round(backtest.MAX_AVG_LEVERAGE * 10_000)
MAX_LIMIT_MICRO = 10_000 * 10**6
APR_BPS = 800


def quantize(row: dict) -> dict:
    return {
        "activeDays": int(row["active_days"]),
        "closes": int(row["n_closes"]),
        "pnlExtMicro": math.floor(float(row["pnl_ext"]) * 1e6),
        "avgLevBps": math.ceil(float(row["avg_lev"]) * 1e4),
        "liqHist": int(row["liq_hist"]),
        "washShareBps": round(float(row["wash_share"]) * 1e4),
        "washPair": bool(row["wash_pair"]),
        "maxDepositMicro": math.floor(max(float(row["max_deposit"]), 0.0) * 1e6),
    }


def eligible(f: dict) -> bool:
    return (f["activeDays"] >= MIN_ACTIVE_DAYS and f["closes"] >= MIN_CLOSES and f["liqHist"] == 0
            and f["pnlExtMicro"] > 0 and f["avgLevBps"] <= MAX_AVG_LEV_BPS and not f["washPair"])


def limit_for(f: dict) -> int:
    return min(f["maxDepositMicro"] * 2, MAX_LIMIT_MICRO) if eligible(f) else 0


def apr_for(f: dict) -> int:
    return APR_BPS if eligible(f) else 0
