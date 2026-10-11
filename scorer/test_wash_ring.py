"""Wash-trading drills against the real feature and approval functions in data/backtest.py.

Each scenario builds synthetic Perpl events: every account opens on 3 days and closes 10 trades at
+100 each, so it would pass every rule on its own. The only difference is who it trades with.
"""
import polars as pl

from data import backtest

EMPTY = pl.DataFrame(
    {"accountId": [], "ts": [], "lev": [], "deposit": [], "fee": [], "pnl": []},
    schema={"accountId": pl.Int64, "ts": pl.Float64, "lev": pl.Float64, "deposit": pl.Float64, "fee": pl.Float64,
            "pnl": pl.Float64},
)


def _score(accounts: list[int], trades: list[tuple[int, int, float]]) -> dict[int, dict]:
    opens, realized = [], []
    for a in accounts:
        for day in range(3):
            opens.append({"accountId": a, "lev": 2.0, "deposit": 1_000.0, "fee": 0.0, "ts": float(day * backtest.DAY)})
        for close in range(10):
            realized.append({"accountId": a, "pnl": 100.0, "ts": float((close + 1) * backtest.DAY)})
    edges = [{"maker": m, "taker": t, "notional": n, "fee": 0.0, "ts": 1.0} for m, t, n in trades]
    tables = {"opens": pl.DataFrame(opens), "incs": EMPTY, "realized": pl.DataFrame(realized), "liqs": EMPTY,
              "edges": pl.DataFrame(edges)}
    scored = backtest.score_margin_line(backtest.features(tables, 20 * backtest.DAY))
    return {r["accountId"]: r for r in scored.to_dicts()}


def _ring(n: int) -> tuple[list[int], list[tuple[int, int, float]]]:
    accounts = [100 + i for i in range(n)]
    return accounts, [(accounts[i], accounts[(i + 1) % n], 10_000.0) for i in range(n)]


def _assert_all_denied(scored: dict[int, dict], accounts: list[int]) -> None:
    for a in accounts:
        assert scored[a]["wash_pair"], f"{a} not flagged"
        assert not scored[a]["ml_approve"], f"{a} approved"
        assert scored[a]["pnl_ext"] == 0.0, f"{a} keeps wash profit {scored[a]['pnl_ext']}"


def test_reciprocal_pair_scores_zero():
    accounts = [101, 202]
    _assert_all_denied(_score(accounts, [(101, 202, 10_000.0), (202, 101, 10_000.0)]), accounts)


def test_three_account_ring_scores_zero():
    accounts, trades = _ring(3)
    _assert_all_denied(_score(accounts, trades), accounts)


def test_five_account_ring_scores_zero():
    accounts, trades = _ring(5)
    _assert_all_denied(_score(accounts, trades), accounts)


def test_ring_hidden_in_outside_volume_is_discounted():
    """A ring that also trades a little with a stranger: still flagged, and only the outside share of
    its profit counts."""
    accounts, trades = _ring(3)
    stranger = 999
    trades = trades + [(a, stranger, 2_000.0) for a in accounts]  # 2,000 outside vs 20,000 inside
    scored = _score(accounts + [stranger], trades)
    for a in accounts:
        assert scored[a]["wash_pair"] and not scored[a]["ml_approve"]
        assert abs(scored[a]["pnl_ext"] - 1_000.0 * (2_000 / 22_000)) < 1e-6


def test_client_of_a_market_maker_is_not_a_wash_trader():
    """Honest order-book trading: many clients each trade almost entirely against one market maker.
    The maker's volume is spread over everyone, so no client links to it and all stay approved."""
    maker = 1
    clients = [100 + i for i in range(10)]
    trades = [(maker, c, 10_000.0) for c in clients]
    scored = _score([maker] + clients, trades)
    for c in clients:
        assert not scored[c]["wash_pair"], f"client {c} wrongly flagged"
        assert scored[c]["ml_approve"], f"client {c} wrongly denied"
        assert scored[c]["pnl_ext"] == 1_000.0
