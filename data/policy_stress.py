"""Retrospective policy comparisons and explicit default-loss scenarios.

Liquidation labels are observed. Loan sizes, LGD and pool balances are modeled,
so the output is neither actual lender loss nor an unseen-period validation.
"""
from __future__ import annotations

import argparse
from bisect import bisect_right
from collections import defaultdict
from datetime import date, timedelta
import hashlib
import json
import math
from pathlib import Path
import platform

import numpy as np

from data.backtest import auc


POLICIES = ("margin_line", "volume", "raw_pnl", "random_sha256_seed7")


def validate_rows(rows: list[dict]) -> None:
    seen = set()
    for row in rows:
        checkpoint = date.fromisoformat(row["checkpoint"])
        if checkpoint.isoformat() != row["checkpoint"]:
            raise ValueError("checkpoint must be an ISO calendar date")
        if type(row["accountId"]) is not int:
            raise ValueError("accountId must be an integer")
        key = row["checkpoint"], row["accountId"]
        if key in seen:
            raise ValueError("duplicate trader/checkpoint")
        seen.add(key)
        if type(row["ml_approve"]) is not bool or type(row["liquidated"]) is not bool:
            raise ValueError("approval and outcome must be boolean")
        for name in ("capital", "volume", "realized_pnl", "ml_score"):
            if isinstance(row[name], bool) or not math.isfinite(row[name]):
                raise ValueError(f"invalid {name}")
        if row["capital"] <= 0 or row["volume"] < 0:
            raise ValueError("capital must be positive and volume nonnegative")


def nonoverlapping(rows: list[dict], start: str, end: str, horizon: int) -> list[dict]:
    """Keep complete, disjoint outcome windows, with an exclusive end date."""
    if type(horizon) is not int or horizon <= 0:
        raise ValueError("horizon must be a positive integer")
    first, last = date.fromisoformat(start), date.fromisoformat(end)
    if first >= last:
        raise ValueError("window must have positive duration")
    allowed, next_date = set(), first
    for checkpoint in sorted({row["checkpoint"] for row in rows}):
        t = date.fromisoformat(checkpoint)
        if t >= next_date and t + timedelta(days=horizon) <= last:
            allowed.add(checkpoint)
            next_date = t + timedelta(days=horizon)
    return [row for row in rows if row["checkpoint"] in allowed]


def select(rows: list[dict], edges: list[float]) -> dict[str, list[dict]]:
    """Match ML approval count within each checkpoint and fixed capital band."""
    if not edges or edges[0] != 0 or edges != sorted(set(edges)):
        raise ValueError("capital bands must increase strictly from zero")
    groups = defaultdict(list)
    for row in rows:
        groups[row["checkpoint"], bisect_right(edges, row["capital"]) - 1].append(row)
    selected = {p: [] for p in POLICIES}
    for key, group in sorted(groups.items()):
        approved = [r for r in group if r["ml_approve"]]
        selected["margin_line"].extend(approved)
        for policy in POLICIES[1:]:
            def rank(row):
                if policy == "random_sha256_seed7":
                    return hashlib.sha256(f"7:{key[0]}:{row['accountId']}".encode()).hexdigest()
                return -row["volume" if policy == "volume" else "realized_pnl"]
            selected[policy].extend(sorted(group, key=lambda r: (rank(r), r["accountId"]))[:len(approved)])
    return {p: sorted(values, key=lambda r: (r["checkpoint"], r["accountId"]))
            for p, values in selected.items()}


def waterfall(loss: int, pool: dict[str, int]) -> dict:
    """Apply CreditPool's reserve, junior, senior loss order in integer units."""
    if type(loss) is not int or loss < 0 or any(type(pool[k]) is not int or pool[k] < 0 for k in ("reserve", "junior", "senior")):
        raise ValueError("loss and balances must be nonnegative integers")
    remaining, paid = loss, {}
    for name in ("reserve", "junior", "senior"):
        paid[name] = min(remaining, pool[name])
        remaining -= paid[name]
    if remaining:
        raise ValueError("loss exceeds pool assets")
    return {"loss_micro": loss, "absorbed_micro": paid,
            "ending_micro": {name: pool[name] - paid[name] for name in paid}}


def snapshot(rows: list[dict], budget: int, pool: dict[str, int], lgd_bps: int,
             *, all_default: bool = False) -> dict:
    if type(budget) is not int or budget < 0 or budget > pool["senior"] + pool["junior"]:
        raise ValueError("loan budget must fit lender capital")
    if type(lgd_bps) is not int or not 0 <= lgd_bps <= 10_000:
        raise ValueError("LGD must be 0..10000 basis points")
    ordered = sorted(rows, key=lambda r: r["accountId"])
    principals = [budget // len(ordered) + (i < budget % len(ordered))
                  for i in range(len(ordered))] if ordered else []
    loss = sum(principal * lgd_bps // 10_000 for principal, row in zip(principals, ordered)
               if all_default or row["liquidated"])
    result = waterfall(loss, pool)
    principal = sum(principals)
    idle = sum(pool.values()) - principal
    assert sum(result["ending_micro"].values()) == idle + principal - loss
    # A simultaneous senior withdrawal while all loans remain outstanding.
    senior_cash = max(0, idle - pool["reserve"])
    result.update(principal_micro=principal, loans=len(ordered),
                  senior_cash_shortfall_while_open_micro=max(0, pool["senior"] - senior_cash),
                  ending_cash_after_full_settlement_micro=idle + principal - loss)
    return result


def clustered_contrasts(selected: dict[str, list[dict]], *, draws: int, seed: int) -> dict:
    """Paired trader bootstrap preserves all selected checkpoints per trader."""
    ids = sorted({r["accountId"] for rows in selected.values() for r in rows})
    if draws <= 0:
        raise ValueError("draws must be positive")
    if not ids:
        return {p: None for p in POLICIES[1:]}
    index = {account: i for i, account in enumerate(ids)}
    counts = np.zeros((len(ids), len(POLICIES)))
    bad = np.zeros_like(counts)
    for j, policy in enumerate(POLICIES):
        for row in selected[policy]:
            counts[index[row["accountId"]], j] += 1
            bad[index[row["accountId"]], j] += row["liquidated"]
    rng = np.random.default_rng(seed)
    samples = []
    for _ in range(draws):
        weights = np.bincount(rng.integers(len(ids), size=len(ids)), minlength=len(ids))
        n = weights @ counts
        rate = np.divide(weights @ bad, n, out=np.full(len(POLICIES), np.nan), where=n > 0)
        samples.append(rate[1:] - rate[0])
    result = {}
    for j, policy in enumerate(POLICIES[1:]):
        finite = np.asarray(samples)[:, j]
        finite = finite[np.isfinite(finite)]
        result[policy] = {"valid_draws": len(finite), "draws": draws, "seed": seed,
                          "baseline_minus_margin_line_ci95": np.quantile(finite, [.025, .975]).tolist() if len(finite) else None}
    return result


def evaluate(rows: list[dict], protocol: dict) -> dict:
    selected = select(rows, protocol["capital_bins_usd"])
    stats = {}
    for policy, values in selected.items():
        by_checkpoint = defaultdict(list)
        for row in values:
            by_checkpoint[row["checkpoint"]].append(row)
        scenarios = {}
        for name, lgd, correlated in [(f"observed_defaults_lgd{bps}", bps, False) for bps in protocol["lgd_bps"]] + [("correlated_all_default", 10_000, True)]:
            snapshots = {t: snapshot(group, protocol["loan_budget_micro"], protocol["pool_micro"], lgd,
                                      all_default=correlated) for t, group in sorted(by_checkpoint.items())}
            scenarios[name] = {"snapshots": snapshots,
                               "total_modeled_loss_micro": sum(s["loss_micro"] for s in snapshots.values()),
                               "max_snapshot_senior_loss_micro": max((s["absorbed_micro"]["senior"] for s in snapshots.values()), default=0)}
        stats[policy] = {"selected_checkpoints": len(values), "unique_selected_traders": len({r["accountId"] for r in values}),
                         "liquidations": sum(r["liquidated"] for r in values),
                         "liquidation_rate": sum(r["liquidated"] for r in values) / len(values) if values else None,
                         "historical_capital_sum_usd": sum(r["capital"] for r in values),
                         "selected_rows": values, "scenarios": scenarios}
    return {"trader_checkpoints": len(rows), "unique_traders": len({r["accountId"] for r in rows}),
            "checkpoints": sorted({r["checkpoint"] for r in rows}), "policies": stats,
            "auc_margin_line": finite_auc(rows),
            "clustered_liquidation_contrasts": clustered_contrasts(selected, **protocol["bootstrap_args"])}


def finite_auc(rows: list[dict]) -> float | None:
    value = auc(np.array([r["ml_score"] for r in rows]), np.array([r["liquidated"] for r in rows], dtype=bool))
    return value if math.isfinite(value) else None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    protocol_bytes = args.protocol.read_bytes()
    protocol = json.loads(protocol_bytes)
    protocol["bootstrap_args"] = {k: protocol["bootstrap"][k] for k in ("draws", "seed")}
    import polars as pl
    results = []
    for filename, expected in protocol["inputs"].items():
        path = Path(filename)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"input fingerprint mismatch: {path}")
        horizon = int(path.stem.rsplit("-h", 1)[1])
        rows = pl.read_parquet(path).to_dicts()
        validate_rows(rows)
        windows = []
        for name, start, end in protocol["windows"]:
            cohort = nonoverlapping(rows, start, end, horizon)
            prior = {r["accountId"] for r in rows if r["checkpoint"] < start}
            windows.append({"name": name, "start": start, "end": end,
                            "all": evaluate(cohort, protocol),
                            "new_to_prior_cohort": evaluate([r for r in cohort if r["accountId"] not in prior], protocol)})
        results.append({"input_sha256": expected, "horizon_days": horizon, "windows": windows})
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "protocol.json").write_bytes(protocol_bytes)
    provenance = {"python": platform.python_version(), "numpy": np.__version__, "polars": pl.__version__,
                  "source_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in (Path(__file__), Path(__file__).with_name("backtest.py"))}}
    (args.output / "results.json").write_text(json.dumps({"protocol_sha256": hashlib.sha256(protocol_bytes).hexdigest(),
                                                        "software": provenance, "results": results}, indent=2, allow_nan=False) + "\n")
    print(f"Wrote {args.output / 'results.json'}")


if __name__ == "__main__":
    main()
