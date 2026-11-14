"""Retrospective purged time checks for frozen Margin Line checkpoint cohorts.

This does not create a prospective holdout, reconstruct applicant eligibility,
or simulate a lender's losses. Inputs already condition on future trading.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import polars as pl

from data.risk_validation import trader_cluster_bootstrap


def split_periods(rows, cutoff: datetime, horizon_days: int):
    if cutoff.tzinfo is None or horizon_days <= 0:
        raise ValueError("timezone-aware cutoff and positive horizon required")
    development, purged, evaluation = [], [], []
    seen = set()
    for row in rows:
        key = row["accountId"], row["checkpoint"]
        if key in seen:
            raise ValueError("duplicate trader/checkpoint")
        seen.add(key)
        checkpoint = datetime.fromisoformat(row["checkpoint"])
        if checkpoint.tzinfo is None:
            checkpoint = checkpoint.replace(tzinfo=timezone.utc)
        # Archived cohorts retain dates rather than exact checkpoint times.
        # Reserve the entire date to avoid leaking a late-day outcome window.
        upper = checkpoint + (timedelta(days=1) if len(row["checkpoint"]) == 10 else timedelta())
        if checkpoint >= cutoff:
            evaluation.append(row)
        elif upper + timedelta(days=horizon_days) <= cutoff:
            development.append(row)
        else:
            purged.append(row)
    if not development or not evaluation:
        raise ValueError("both development and evaluation periods need rows")
    return development, purged, evaluation


def auc_good(score, bad):
    score, bad = np.asarray(score, dtype=float), np.asarray(bad, dtype=bool)
    if not len(score) or bad.all() or not bad.any():
        return None
    order = np.argsort(score, kind="stable")
    sorted_values = score[order]
    ranks = np.empty(len(score), dtype=float)
    start = 0
    while start < len(score):
        end = start + 1
        while end < len(score) and sorted_values[end] == sorted_values[start]:
            end += 1
        ranks[order[start:end]] = (start + 1 + end) / 2
        start = end
    good_n, bad_n = int((~bad).sum()), int(bad.sum())
    return float((ranks[~bad].sum() - good_n * (good_n + 1) / 2) / (good_n * bad_n))


def fit_calibration(development):
    """One score, two coefficients. No evaluation outcomes enter fitting."""
    x = np.array([[1., row["ml_score"]] for row in development])
    y = np.array([row["liquidated"] for row in development], dtype=float)
    if not np.isfinite(x).all():
        raise ValueError("calibration scores must be finite")
    prior = float(np.clip(y.mean(), 1e-6, 1 - 1e-6))
    beta = np.array([math.log(prior / (1 - prior)), 0.])
    for _ in range(50):
        probability = 1 / (1 + np.exp(-np.clip(x @ beta, -30, 30)))
        penalty = np.diag([1e-8, 1e-4])
        gradient = x.T @ (probability - y) + penalty @ beta
        hessian = (x.T * (probability * (1 - probability))) @ x + penalty
        step = np.linalg.solve(hessian, gradient)
        beta -= step
        if np.max(np.abs(step)) < 1e-8:
            break
    return {"intercept": float(beta[0]), "slope": float(beta[1]), "development_base_rate": prior}


def calibration_metrics(rows, model):
    y = np.array([r["liquidated"] for r in rows], dtype=float)
    score = np.array([r["ml_score"] for r in rows])
    p = 1 / (1 + np.exp(-np.clip(model["intercept"] + model["slope"] * score, -30, 30)))
    reliability = []
    for lo, hi in zip([0., .05, .1, .2, .4], [.05, .1, .2, .4, 1.000001]):
        mask = (p >= lo) & (p < hi)
        reliability.append({"probability_band": [lo, min(hi, 1.)], "count": int(mask.sum()),
                            "mean_predicted": float(p[mask].mean()) if mask.any() else None,
                            "observed_rate": float(y[mask].mean()) if mask.any() else None})
    return {"brier": float(np.mean((p - y) ** 2)),
            "constant_development_prior_brier": float(np.mean((model["development_base_rate"] - y) ** 2)),
            "mean_predicted": float(p.mean()), "observed_rate": float(y.mean()),
            "reliability": reliability}


def matched_capital(rows, *, max_ratio=2.):
    """Equal-count, no-reuse matches inside a checkpoint, with a fixed caliper.

    Capital is a historic deposit feature, not actual capital deployed by a lender.
    """
    groups = defaultdict(list)
    for row in rows:
        if row["capital"] > 0 and math.isfinite(row["capital"]):
            groups[row["checkpoint"]].append(row)
    result, gaps = [], []
    for checkpoint in sorted(groups):
        group = groups[checkpoint]
        approved = sorted([r for r in group if r["ml_approve"]], key=lambda r: (r["capital"], r["accountId"]))
        candidates = [r for r in group if r["exp_approve"] and not r["ml_approve"]]
        for row in approved:
            if not candidates:
                break
            index = min(range(len(candidates)), key=lambda i: (abs(math.log(row["capital"] / candidates[i]["capital"])), candidates[i]["accountId"]))
            other = candidates[index]
            gap = abs(math.log(row["capital"] / other["capital"]))
            if gap <= math.log(max_ratio):
                result.extend([row, candidates.pop(index)])
                gaps.append(gap)
    return result, {"pairs": len(gaps), "max_capital_ratio": max_ratio,
                    "median_log_capital_gap": float(np.median(gaps)) if gaps else None,
                    "eligible_approved_rows": sum(bool(r["ml_approve"]) for r in rows)}


def period_report(rows, model, *, draws):
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["checkpoint"]].append(row)
    ranking = {}
    for name in ["ml_score", "volume", "realized_pnl"]:
        values = [auc_good([r[name] for r in group], [r["liquidated"] for r in group])
                  for group in grouped.values()]
        finite = [v for v in values if v is not None]
        ranking[name] = {"macro_checkpoint_auc_good": float(np.mean(finite)) if finite else None,
                         "checkpoints_with_both_outcomes": len(finite)}
    matched, match_info = matched_capital(rows)
    experience = [r for r in rows if r["exp_approve"]]
    return {"rows": len(rows), "traders": len({r["accountId"] for r in rows}),
            "checkpoints": sorted(grouped), "approval_rows": sum(r["ml_approve"] for r in rows),
            "association": trader_cluster_bootstrap(rows, draws=draws, seed=1729),
            "experience_only_rate": sum(r["liquidated"] for r in experience) / len(experience) if experience else None,
            "ranking": ranking, "calibration": calibration_metrics(rows, model),
            "capital_match": {**match_info, "association": trader_cluster_bootstrap(matched, draws=draws, seed=1729) if matched else None}}


def finite_json(value):
    if isinstance(value, dict):
        return {k: finite_json(v) for k, v in value.items()}
    if isinstance(value, list):
        return [finite_json(v) for v in value]
    return None if isinstance(value, float) and not math.isfinite(value) else value


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cohort", type=Path, required=True)
    ap.add_argument("--cutoff", required=True, help="timezone-aware ISO timestamp")
    ap.add_argument("--horizon-days", type=int, choices=[7, 14], required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--draws", type=int, default=2000)
    args = ap.parse_args()
    if args.output.exists():
        raise SystemExit("Refusing to overwrite a previous analysis")
    rows = pl.read_parquet(args.cohort).to_dicts()
    required = {"accountId", "checkpoint", "ml_approve", "exp_approve", "liquidated", "ml_score", "capital", "volume", "realized_pnl"}
    if not rows or not required.issubset(rows[0]):
        raise ValueError("Cohort schema is incomplete")
    for row in rows:
        if any(not isinstance(row[k], bool) for k in ["ml_approve", "exp_approve", "liquidated"]):
            raise ValueError("Policy/outcome labels must be boolean")
        if any(not math.isfinite(row[k]) for k in ["ml_score", "capital", "volume", "realized_pnl"]):
            raise ValueError("Cohort features must be finite")
    cutoff = datetime.fromisoformat(args.cutoff.replace("Z", "+00:00"))
    development, purged, evaluation = split_periods(rows, cutoff, args.horizon_days)
    model = fit_calibration(development)
    known = {r["accountId"] for r in development}
    report = {"protocol": {"cutoff": args.cutoff, "horizon_days": args.horizon_days,
                           "cohort_sha256": hashlib.sha256(args.cohort.read_bytes()).hexdigest(),
                           "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                           "uncertainty_helper_sha256": hashlib.sha256(Path(__file__).with_name("risk_validation.py").read_bytes()).hexdigest(),
                           "draws": args.draws, "seed": 1729, "purged_rows": len(purged),
                           "purged_checkpoints": sorted({r["checkpoint"] for r in purged}),
                           "development_traders": len(known), "calibration_fit": model},
              "development": period_report(development, model, draws=args.draws),
              "evaluation": period_report(evaluation, model, draws=args.draws),
              "evaluation_by_development_membership": {},
              "limitations": ["Retrospective chronological evaluation on a previously inspected historical window, not prospective or untouched data.",
                              "Stored date-only checkpoint precision is handled with a conservative extra day in development purging.",
                              "Cohort includes only traders who continued trading after the checkpoint; future-activity conditioning is not known applicant eligibility at decision time.",
                              "Trader-cluster bootstrap handles repeated accounts but not common calendar/market shocks across traders.",
                              "Capital matching uses historic deposit features, not matched actual loan exposure; no economic loss or causal credit-policy benefit is established.",
                              "New to development cohort does not mean a new account or no prior trading history.",
                              "Risk calibration is fit only on development outcomes; discrimination and calibration are separate tests."]}
    for name, member in [("seen_in_development", True), ("not_seen_in_development", False)]:
        subset = [r for r in evaluation if (r["accountId"] in known) == member]
        report["evaluation_by_development_membership"][name] = period_report(subset, model, draws=args.draws) if subset else None
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(finite_json(report), indent=2, allow_nan=False))
    print(json.dumps({"development_rows": len(development), "purged_rows": len(purged), "evaluation_rows": len(evaluation),
                      "evaluation": finite_json(report["evaluation"])}, indent=2))


if __name__ == "__main__":
    main()
