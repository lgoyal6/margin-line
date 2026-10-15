from copy import deepcopy
import hashlib
import json
import subprocess
import sys

import numpy as np
import pytest

from data.policy_stress import (
    clustered_contrasts, nonoverlapping, select, snapshot, validate_rows, waterfall,
)


def row(account=1, checkpoint="2026-06-01", **kwargs):
    return dict(accountId=account, checkpoint=checkpoint, ml_approve=False,
                liquidated=False, capital=100., volume=10., realized_pnl=5.,
                ml_score=0.5) | kwargs


def test_disjoint_outcomes_and_terminal_boundary():
    rows = [row(checkpoint=f"2026-06-{day:02}") for day in (1, 8, 15, 22, 29)]
    assert [r["checkpoint"] for r in nonoverlapping(rows, "2026-06-01", "2026-06-29", 14)] == ["2026-06-01", "2026-06-15"]
    assert nonoverlapping(rows, "2026-05-01", "2026-06-01", 7) == []


def test_baselines_match_count_within_capital_band_and_never_use_outcomes():
    rows = [row(1, ml_approve=True), row(2, volume=30),
            row(3, capital=1000, ml_approve=True), row(4, capital=1000, volume=40)]
    chosen = select(rows, [0, 250, 1000])
    assert [r["accountId"] for r in chosen["volume"]] == [2, 4]
    for values in chosen.values():
        assert len(values) == 2
        assert sum(r["capital"] < 250 for r in values) == 1
    changed = deepcopy(rows)
    for r in changed:
        r["liquidated"] = not r["liquidated"]
    again = select(changed[::-1], [0, 250, 1000])
    assert {p: [r["accountId"] for r in v] for p, v in chosen.items()} == {p: [r["accountId"] for r in v] for p, v in again.items()}


def test_ties_use_account_id_and_no_approvals_means_no_loans():
    rows = [row(3), row(2), row(1, ml_approve=True)]
    assert select(rows, [0])["volume"][0]["accountId"] == 1
    assert all(not v for v in select([row()], [0]).values())


@pytest.mark.parametrize("change", [dict(liquidated=None), dict(liquidated=1), dict(capital=float("nan")), dict(capital=0), dict(volume=-1), dict(accountId=True)])
def test_invalid_or_missing_outcomes_refuse(change):
    with pytest.raises(ValueError):
        validate_rows([row(**change)])


def test_missing_outcome_and_duplicate_trader_checkpoint_refuse():
    missing = row()
    del missing["liquidated"]
    with pytest.raises(KeyError):
        validate_rows([missing])
    with pytest.raises(ValueError, match="duplicate"):
        validate_rows([row(), row()])


def test_hand_calculated_contract_waterfall_reaches_senior():
    # CreditPool.t.sol's interest-funded balances and successive 1M/100k losses.
    pool = dict(reserve=10_000, junior=1_026_000, senior=4_064_000)
    first = waterfall(1_000_000, pool)
    assert first["absorbed_micro"] == dict(reserve=10_000, junior=990_000, senior=0)
    second = waterfall(100_000, first["ending_micro"])
    assert second["absorbed_micro"] == dict(reserve=0, junior=36_000, senior=64_000)
    assert second["ending_micro"] == dict(reserve=0, junior=0, senior=4_000_000)


def test_exposure_conservation_correlated_defaults_and_open_cash_shortfall():
    rows = [row(1, liquidated=True), row(2), row(3)]
    pool = dict(reserve=10, junior=20, senior=80)
    observed = snapshot(rows, 90, pool, 10_000)
    assert observed["principal_micro"] == 90
    assert observed["loss_micro"] == 30
    assert observed["absorbed_micro"] == dict(reserve=10, junior=20, senior=0)
    assert observed["senior_cash_shortfall_while_open_micro"] == 70
    assert sum(observed["ending_micro"].values()) == observed["ending_cash_after_full_settlement_micro"] == 80
    correlated = snapshot(rows, 90, pool, 10_000, all_default=True)
    assert correlated["loss_micro"] == 90
    assert correlated["absorbed_micro"]["senior"] == 60
    assert snapshot(rows, 90, pool, 0)["loss_micro"] == 0


def test_principal_remainder_and_empty_snapshot_conserve_units():
    pool = dict(reserve=0, junior=10, senior=90)
    assert snapshot([row(1, liquidated=True), row(2), row(3)], 10, pool, 10_000)["loss_micro"] == 4
    assert snapshot([], 10, pool, 10_000)["principal_micro"] == 0
    with pytest.raises(ValueError):
        waterfall(101, pool)
    with pytest.raises(ValueError):
        snapshot([row()], 101, pool, 10_000)


def test_paired_cluster_bootstrap_keeps_identical_policy_contrast_zero():
    rows = [row(1, liquidated=True), row(1, checkpoint="2026-06-15", liquidated=True), row(2)]
    selected = {p: rows for p in ("margin_line", "volume", "raw_pnl", "random_sha256_seed7")}
    result = clustered_contrasts(selected, draws=200, seed=7)
    assert all(v["baseline_minus_margin_line_ci95"] == [0., 0.] and v["valid_draws"] == 200 for v in result.values())
    assert result == clustered_contrasts(selected, draws=200, seed=7)


def test_cluster_intervals_match_whole_trader_reference():
    ml = [row(1, liquidated=True), row(1, checkpoint="2026-06-15", liquidated=True), row(2)]
    baseline = [row(1), row(2), row(2, checkpoint="2026-06-15")]
    selected = dict(margin_line=ml, volume=baseline, raw_pnl=baseline, random_sha256_seed7=baseline)
    result = clustered_contrasts(selected, draws=200, seed=7)
    rng = np.random.default_rng(7)
    differences = []
    for _ in range(200):
        accounts = rng.integers(2, size=2) + 1
        sample = [r for account in accounts for r in ml if r["accountId"] == account]
        differences.append(-sum(r["liquidated"] for r in sample) / len(sample))
    assert result["volume"]["baseline_minus_margin_line_ci95"] == np.quantile(differences, [.025, .975]).tolist()


def test_cli_binds_inputs_retains_protocol_and_refuses_overwrite(tmp_path):
    import polars as pl

    cohort = tmp_path / "cohort-h7.parquet"
    pl.DataFrame([row(1, ml_approve=True, liquidated=True), row(2)]).write_parquet(cohort)
    protocol = dict(inputs={str(cohort): hashlib.sha256(cohort.read_bytes()).hexdigest()},
                    windows=[["diagnostic_holdout_reused", "2026-06-01", "2026-06-08"]],
                    capital_bins_usd=[0, 250], loan_budget_micro=90,
                    pool_micro=dict(reserve=10, junior=20, senior=80), lgd_bps=[1000, 10_000],
                    bootstrap=dict(draws=20, seed=7))
    frozen = tmp_path / "protocol.json"
    frozen.write_text(json.dumps(protocol))
    output = tmp_path / "result"
    command = [sys.executable, "-m", "data.policy_stress", "--protocol", str(frozen), "--output", str(output)]
    first = subprocess.run(command, capture_output=True, text=True)
    assert first.returncode == 0, first.stderr
    assert (output / "protocol.json").read_bytes() == frozen.read_bytes()
    results = json.loads((output / "results.json").read_text())
    assert results["protocol_sha256"] == hashlib.sha256(frozen.read_bytes()).hexdigest()
    result_bytes = (output / "results.json").read_bytes()
    assert subprocess.run(command, capture_output=True).returncode != 0
    assert (output / "results.json").read_bytes() == result_bytes
    cohort.write_bytes(cohort.read_bytes() + b"changed")
    wrong = subprocess.run(command[:-1] + [str(tmp_path / "new-result")], capture_output=True, text=True)
    assert wrong.returncode != 0 and "fingerprint mismatch" in wrong.stderr
    assert not (tmp_path / "new-result").exists()
