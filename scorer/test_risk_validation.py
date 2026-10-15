import pytest
import polars as pl

from data import backtest
from data.risk_validation import trader_cluster_bootstrap


def rows():
    return [
        {"accountId": 1, "checkpoint": "2026-01-01", "ml_approve": True, "liquidated": False},
        {"accountId": 1, "checkpoint": "2026-01-08", "ml_approve": True, "liquidated": False},
        {"accountId": 2, "checkpoint": "2026-01-01", "ml_approve": False, "liquidated": True},
        {"accountId": 2, "checkpoint": "2026-01-08", "ml_approve": False, "liquidated": True},
    ]


def test_bootstrap_resamples_traders_and_reproduces_from_seed():
    result = trader_cluster_bootstrap(rows(), draws=500, seed=11)
    assert result["unique_traders"] == 2
    assert result["trader_checkpoints"] == 4
    assert result["point_estimates"] == {
        "approved_liquidation_rate": 0.0,
        "denied_liquidation_rate": 1.0,
        "approved_minus_denied": -1.0,
    }
    assert result == trader_cluster_bootstrap(rows(), draws=500, seed=11)


def test_malformed_cohort_is_rejected():
    with pytest.raises(ValueError, match="missing: liquidated"):
        trader_cluster_bootstrap([{"accountId": 1, "checkpoint": "t", "ml_approve": True}])


def test_empty_cohort_is_rejected():
    with pytest.raises(ValueError, match="must not be empty"):
        trader_cluster_bootstrap([])


def test_future_events_do_not_change_pre_cutoff_features():
    empty = pl.DataFrame({
        "accountId": [], "ts": [], "lev": [], "deposit": [], "fee": [], "pnl": []
    }, schema={
        "accountId": pl.Int64, "ts": pl.Float64, "lev": pl.Float64,
        "deposit": pl.Float64, "fee": pl.Float64, "pnl": pl.Float64,
    })
    base = {
        "opens": pl.DataFrame([{"accountId": 1, "ts": 1.0, "lev": 2.0, "deposit": 100.0, "fee": 0.0}]),
        "incs": empty,
        "realized": pl.DataFrame([{"accountId": 1, "ts": 2.0, "pnl": 10.0}]),
        "liqs": empty,
        "edges": pl.DataFrame({"maker": [], "taker": [], "notional": [], "fee": [], "ts": []}, schema={
            "maker": pl.Int64, "taker": pl.Int64, "notional": pl.Float64, "fee": pl.Float64, "ts": pl.Float64,
        }),
    }
    changed = {**base, "realized": pl.concat([base["realized"], pl.DataFrame([{"accountId": 1, "ts": 11.0, "pnl": 1_000_000.0}])])}
    cutoff = 10.0
    assert backtest.features(base, cutoff).equals(backtest.features(changed, cutoff))
