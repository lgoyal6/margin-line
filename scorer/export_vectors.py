"""Write test/fixtures/score_vectors.json for the Python-vs-Solidity differential test.

Two kinds of vectors:
- every account scored by the backtest at the cutoff block (real Perpl history);
- boundary vectors: each rule exactly at its threshold and one unit either side, plus the limit cap.

Every vector's float verdict comes from `backtest.score_margin_line` itself (the rule is called,
not reimplemented). Expected values in the fixture are the integer rule (`scorer/rules.py`), which
is what leaves carry and what Solidity must match. The script fails if the integer rule is ever
more permissive than the float rule, and on boundary vectors it requires exact agreement.

Usage: .agent-work/venv/bin/python -m scorer.export_vectors [--cutoff-block N]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import polars as pl

from scorer import rules
from scorer.epoch import backtest, scored_rows

OUT = Path(__file__).resolve().parents[1] / "test" / "fixtures" / "score_vectors.json"

BASE = {"active_days": 5, "n_closes": 12, "liq_hist": 0, "pnl_ext": 100.0, "avg_lev": 2.0, "wash_pair": False,
        "top_cp_share": 0.1, "wash_share": 0.0, "max_deposit": 1_000.0, "ret_ext": 0.1, "win_rate": 0.5, "dd_ratio": 0.1}


def boundary_rows() -> list[dict]:
    rows = []
    for d in (2, 3, 4):
        rows.append(BASE | {"active_days": d})
    for c in (9, 10, 11):
        rows.append(BASE | {"n_closes": c})
    for liq in (0, 1):
        rows.append(BASE | {"liq_hist": liq})
    for pnl in (-0.000001, 0.0, 0.000001):  # -1, 0, +1 micro-AUSD
        rows.append(BASE | {"pnl_ext": pnl})
    for lev in (4.9999, 5.0, 5.0001):  # 49,999 / 50,000 / 50,001 bps
        rows.append(BASE | {"avg_lev": lev})
    for wash in (False, True):
        rows.append(BASE | {"wash_pair": wash})
    for dep in (4_999.999999, 5_000.0, 5_000.000001, 0.0, 20_000.0):  # limit just under, at, over the cap
        rows.append(BASE | {"max_deposit": dep})
    return rows


def float_verdicts(rows: list[dict]) -> list[bool]:
    return backtest.score_margin_line(pl.DataFrame(rows))["ml_approve"].to_list()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cutoff-block", type=int, default=backtest.END_BLOCK)
    args = ap.parse_args()

    real = scored_rows(args.cutoff_block)
    bound = boundary_rows()
    vectors, flips = [], 0
    for row, float_ok, is_boundary in [(r, bool(r["ml_approve"]), False) for r in real] + \
            [(r, v, True) for r, v in zip(bound, float_verdicts(bound))]:
        f = rules.quantize(row)
        int_ok = rules.eligible(f)
        if int_ok and not float_ok:
            raise SystemExit(f"integer rule more permissive than the backtest: {row}")
        if is_boundary and int_ok != float_ok:
            raise SystemExit(f"boundary vector disagrees with the backtest: {row}")
        flips += float_ok and not int_ok
        vectors.append(f | {"eligible": int_ok, "limitMicro": rules.limit_for(f)})

    keys = ["activeDays", "closes", "pnlExtMicro", "avgLevBps", "liqHist", "washShareBps", "washPair",
            "maxDepositMicro", "eligible", "limitMicro"]
    fixture = {k: [v[k] for v in vectors] for k in keys}
    OUT.write_text(json.dumps(fixture, separators=(",", ":")) + "\n")
    print(json.dumps({"vectors": len(vectors), "real": len(real), "boundary": len(bound),
                      "eligible": sum(fixture["eligible"]), "roundingDenials": flips, "out": str(OUT)}))


if __name__ == "__main__":
    main()
