"""Trader-clustered uncertainty for the frozen credit-policy study."""
from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterable, Mapping

import numpy as np


REQUIRED = ("accountId", "checkpoint", "ml_approve", "liquidated")


def _rate(rows: list[Mapping], approved: bool) -> float:
    cohort = [row for row in rows if bool(row["ml_approve"]) is approved]
    return float(np.mean([bool(row["liquidated"]) for row in cohort])) if cohort else float("nan")


def trader_cluster_bootstrap(
    rows: Iterable[Mapping], *, draws: int = 2_000, seed: int = 7
) -> dict:
    """Resample whole traders, retaining each sampled trader's checkpoints.

    The result is conditional on the supplied policy and cohort. It does not
    match capital exposure, establish causal effects, or replace a held-out
    time-period design.
    """
    data = list(rows)
    if draws < 1:
        raise ValueError("draws must be positive")
    if not data:
        raise ValueError("rows must not be empty")
    for index, row in enumerate(data):
        missing = [key for key in REQUIRED if key not in row]
        if missing:
            raise ValueError(f"row {index} missing: {', '.join(missing)}")
        if not isinstance(row["ml_approve"], (bool, np.bool_)) or not isinstance(row["liquidated"], (bool, np.bool_)):
            raise ValueError(f"row {index} approval and liquidation labels must be boolean")

    clusters: dict[object, list[Mapping]] = defaultdict(list)
    for row in data:
        clusters[row["accountId"]].append(row)
    ids = np.array(list(clusters), dtype=object)
    point = {
        "approved_liquidation_rate": _rate(data, True),
        "denied_liquidation_rate": _rate(data, False),
    }
    point["approved_minus_denied"] = point["approved_liquidation_rate"] - point["denied_liquidation_rate"]

    rng = np.random.default_rng(seed)
    samples = np.empty((draws, 3), dtype=float)
    for i in range(draws):
        selected = rng.choice(ids, size=len(ids), replace=True)
        sample = [row for trader in selected for row in clusters[trader]]
        approved = _rate(sample, True)
        denied = _rate(sample, False)
        samples[i] = approved, denied, approved - denied

    intervals = {}
    for col, name in enumerate(("approved_liquidation_rate", "denied_liquidation_rate", "approved_minus_denied")):
        finite = samples[np.isfinite(samples[:, col]), col]
        intervals[name] = [float(np.quantile(finite, 0.025)), float(np.quantile(finite, 0.975))] if len(finite) else None
    return {
        "schema_version": 1,
        "trader_checkpoints": len(data),
        "unique_traders": len(clusters),
        "draws_requested": draws,
        "draws_with_both_policy_groups": int(np.isfinite(samples[:, 2]).sum()),
        "point_estimates": point,
        "cluster_bootstrap_ci95": intervals,
        "seed": seed,
        "limitations": [
            "Repeated checkpoints are resampled together by trader.",
            "The input must already be a frozen held-out cohort; this function does not select periods or match capital exposure.",
            "The contrast is associational and does not establish lending viability.",
        ],
    }
