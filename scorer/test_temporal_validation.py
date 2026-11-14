from datetime import datetime, timezone

import numpy as np
import pytest

from data.temporal_validation import (auc_good, calibration_metrics, fit_calibration,
                                     matched_capital, split_periods)


def row(account, date, approved=False, bad=False, capital=100., score=0.):
    return {"accountId": account, "checkpoint": date, "ml_approve": approved,
            "liquidated": bad, "exp_approve": True, "capital": capital,
            "ml_score": score, "volume": 100., "realized_pnl": 10.}


def test_outcome_windows_crossing_cutoff_are_purged_and_dates_are_conservative():
    data = [row(1, "2026-07-24"), row(2, "2026-07-25"), row(3, "2026-08-01")]
    dev, purge, test = split_periods(data, datetime(2026, 8, 1, tzinfo=timezone.utc), 7)
    assert [r["accountId"] for r in dev] == [1]
    assert [r["accountId"] for r in purge] == [2]
    assert [r["accountId"] for r in test] == [3]


def test_exact_timestamp_boundary_can_finish_at_cutoff():
    data = [row(1, "2026-07-25T00:00:00+00:00"), row(2, "2026-08-01")]
    assert len(split_periods(data, datetime(2026, 8, 1, tzinfo=timezone.utc), 7)[0]) == 1


def test_duplicate_observations_are_rejected():
    with pytest.raises(ValueError, match="duplicate"):
        split_periods([row(1, "2026-01-01")] * 2, datetime(2026, 8, 1, tzinfo=timezone.utc), 7)


def test_naive_cutoff_is_rejected():
    with pytest.raises(ValueError, match="timezone-aware"):
        split_periods([], datetime(2026, 8, 1), 7)


def test_auc_ties_and_direction_are_explicit():
    assert auc_good([1, 1], [True, False]) == .5
    assert auc_good([0, 1], [True, False]) == 1.
    assert auc_good([1, 0], [True, False]) == 0.
    assert auc_good([1, 2], [False, False]) is None


def test_calibration_is_fit_on_development_only():
    dev = [row(i, "2026-01-01", bad=i < 10, score=i / 10) for i in range(20)]
    model = fit_calibration(dev)
    assert model["slope"] < 0
    before = dict(model)
    calibration_metrics([row(90, "2026-09-01", bad=True, score=10)], model)
    assert model == before
    assert fit_calibration(dev) == model


def test_constant_score_calibration_remains_finite():
    model = fit_calibration([row(i, "2026-01-01", bad=i % 2 == 0) for i in range(10)])
    assert all(np.isfinite(v) for v in model.values())


def test_capital_matches_do_not_reuse_or_cross_checkpoints():
    data = [row(1, "a", True), row(2, "a", True), row(3, "a"), row(4, "b")]
    matched, info = matched_capital(data)
    assert info["pairs"] == 1
    assert len(matched) == 2
    assert {r["checkpoint"] for r in matched} == {"a"}


def test_experience_and_capital_caliper_are_not_ignored():
    denied = row(3, "a")
    denied["exp_approve"] = False
    matches, _ = matched_capital([row(1, "a", True), row(2, "a", capital=1000.), denied])
    assert matches == []


def test_empty_period_is_not_reported_as_a_successful_holdout():
    with pytest.raises(ValueError, match="both development"):
        split_periods([row(1, "2026-01-01")], datetime(2026, 8, 1, tzinfo=timezone.utc), 7)
