"""Phase 1: does the Margin Line credit score predict who gets liquidated?

Walk-forward backtest on real Perpl mainnet history. At each checkpoint T, every trader is scored using
only events before T. Outcome: among traders who keep trading in (T, T+H], who is liquidated.

The scoring rule below was fixed before looking at any outcome. If it is ever tuned, the tuning must
be judged on checkpoints it did not see.

Scores compared:
  margin_line  approve/deny rule plus a continuous rank score (see `score_margin_line`)
  volume       rank by traded notional, what a naive lender or a volume-based prop firm would use
  raw_pnl      rank by realized PnL with no self-trading filter
  random       control

Usage: .agent-work/venv/bin/python data/backtest.py [--horizon-days 7]
Writes data/derived/backtest/report.json and prints a summary.
"""

import argparse
import json
import math
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import polars as pl

HERE = Path(__file__).resolve().parent
EV = HERE / "derived" / "events"
OUT = HERE / "derived" / "backtest"

def continuous_range() -> tuple:
    """Largest gap-free block range in data/raw/history (chunk names are <from>-<to>)."""
    spans = sorted(tuple(int(x) for x in p.name.split(".")[0].split("-")) for p in (HERE / "raw" / "history").glob("*.jsonl.gz"))
    best, cur = (0, 0), None
    for a, b in spans:
        cur = (a, b) if cur is None or a != cur[1] else (cur[0], b)
        if cur[1] - cur[0] > best[1] - best[0]:
            best = cur
    return best


START_BLOCK, END_BLOCK = continuous_range()
DAY = 86_400

# Perpl mainnet market decimals (price, lot), read from getPerpetualInfo. Collateral (AUSD) has 6.
DECIMALS = {1: (1, 5), 10: (6, 0), 20: (2, 3), 31: (3, 3), 40: (4, 2), 50: (2, 4), 60: (5, 1),
            70: (4, 2), 90: (6, 0), 100: (4, 2), 110: (4, 2)}

# Fixed approval rule (set before seeing outcomes).
MIN_ACTIVE_DAYS = 3
MIN_CLOSES = 10
MAX_AVG_LEVERAGE = 5.0
WASH_SHARE = 0.5  # an account trading at least this share of its volume inside its cluster is a wash trader
WASH_EDGE_SHARE = 0.2  # two accounts are linked when each is at least this share of the other's volume


def block_time() -> callable:
    pts = json.loads((HERE / "block_timestamps.json").read_text())
    b = np.array([p[0] for p in pts], dtype=np.float64)
    t = np.array([p[1] for p in pts], dtype=np.float64)
    return lambda blocks: np.interp(np.asarray(blocks, dtype=np.float64), b, t)


def load(name: str) -> pl.DataFrame:
    p = EV / f"{name}.parquet"
    if not p.exists():
        return pl.DataFrame()
    return pl.read_parquet(p).filter((pl.col("block") >= START_BLOCK) & (pl.col("block") < END_BLOCK))


def usd(cns: pl.Expr) -> pl.Expr:
    return cns.cast(pl.Float64) / 1e6


def notional_usd(price: pl.Expr, lot: pl.Expr, perp: pl.Expr) -> pl.Expr:
    scale = perp.replace_strict({k: 10 ** (p + l) for k, (p, l) in DECIMALS.items()}, default=None)
    return price.cast(pl.Float64) * lot.cast(pl.Float64) / scale.cast(pl.Float64)


def build_tables(to_ts):
    """Per-account event tables with timestamps and USD amounts."""
    opens = load("PositionOpenedV2").select(
        "block", "tx", "accountId", "perpId",
        (pl.col("leverageHdths") / 100).alias("lev"), usd(pl.col("depositCNS")).alias("deposit"),
        usd(pl.col("insFeeCNS") + pl.col("protFeeCNS")).alias("fee"),
    )
    incs = load("PositionIncreasedV2").select(
        "block", "tx", "accountId", "perpId",
        (pl.col("leverageHdths") / 100).alias("lev"), usd(pl.col("endDepositCNS") - pl.col("startDepositCNS")).alias("deposit"),
        usd(pl.col("insFeeCNS") + pl.col("protFeeCNS")).alias("fee"),
    )
    realized = pl.concat([
        load(n).select("block", "tx", "accountId", "perpId", usd(pl.col("deltaPnlCNS") + pl.col("fundingCNS")).alias("pnl"))
        for n in ("PositionDecreased", "PositionClosed", "PositionInverted")
    ])
    liqs = load("PositionLiquidated").select(
        "block", "tx", pl.col("posAccountId").alias("accountId"), "perpId",
        usd(pl.col("deltaPnlCNS") + pl.col("fundingCNS")).alias("pnl"), usd(pl.col("posDepositCNS")).alias("deposit"),
    )
    maker = pl.concat([
        load(n).select("block", "tx", "accountId", "perpId", "pricePNS", "lotLNS", usd(pl.col("feeCNS")).alias("fee"))
        for n in ("MakerOrderFilled", "MakerOrderFilledV2")
    ]).with_columns(notional_usd(pl.col("pricePNS"), pl.col("lotLNS"), pl.col("perpId")).alias("notional"))

    # Taker of each fill: the account with a position event in the same transaction that is not a maker.
    pos_accts = pl.concat([t.select("tx", "accountId") for t in (opens, incs, realized, liqs)]).unique()
    makers_in_tx = maker.select("tx", "accountId").unique()
    takers = pos_accts.join(makers_in_tx, on=["tx", "accountId"], how="anti")
    takers = takers.group_by("tx").agg(pl.col("accountId").first().alias("taker"), pl.len().alias("n")).filter(pl.col("n") == 1)
    edges = maker.join(takers.select("tx", "taker"), on="tx", how="inner").rename({"accountId": "maker"})

    def ts(df):
        return df.with_columns(pl.Series("ts", to_ts(df["block"].to_numpy())))

    return {k: ts(v) for k, v in dict(opens=opens, incs=incs, realized=realized, liqs=liqs, maker=maker, edges=edges).items()}


def _wash_clusters(pair: pl.DataFrame, vol: pl.DataFrame) -> pl.DataFrame:
    """Groups of accounts that trade mostly with each other.

    Two accounts are linked when each is at least WASH_EDGE_SHARE of the other's volume. Requiring
    both sides keeps honest traders out: a market maker spreads its volume over many clients, so a
    client that trades mostly against it is still a tiny share of the maker's volume and never links.
    Linked accounts form clusters (connected components); `wash_share` is the share of an account's
    volume traded with members of its own cluster, and it is a wash trader at WASH_SHARE or more.
    A reciprocal pair is the two-account case; rings of any length are caught the same way.
    """
    shares = pair.join(vol, on="a").join(vol.rename({"a": "b", "volume": "volume_b"}), on="b").with_columns(
        (pl.col("notional") / pl.col("volume")).alias("share_ab"), (pl.col("notional") / pl.col("volume_b")).alias("share_ba")
    )
    strong = shares.filter((pl.col("share_ab") >= WASH_EDGE_SHARE) & (pl.col("share_ba") >= WASH_EDGE_SHARE))
    parent: dict[int, int] = {}

    def find(x: int) -> int:
        while parent.setdefault(x, x) != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b in strong.select("a", "b").iter_rows():
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)
    accounts = vol["a"].to_list()
    cluster = pl.DataFrame({"a": accounts, "cluster": [find(a) for a in accounts]}, schema={"a": pl.Int64, "cluster": pl.Int64})
    internal = (
        shares.join(cluster, on="a").join(cluster.rename({"a": "b", "cluster": "cluster_b"}), on="b")
        .filter(pl.col("cluster") == pl.col("cluster_b")).group_by("a").agg(pl.col("share_ab").sum().alias("wash_share"))
    )
    return vol.join(internal, on="a", how="left").with_columns(pl.col("wash_share").fill_null(0.0)).with_columns(
        (pl.col("wash_share") >= WASH_SHARE).alias("wash_pair")
    )


def features(t: dict, T: float, lookback_days: int = 10_000) -> pl.DataFrame:
    """Everything known about each account strictly before T."""
    lo = T - lookback_days * DAY
    before = lambda df: df.filter((pl.col("ts") < T) & (pl.col("ts") >= lo))
    opens, incs, realized, liqs, edges = (before(t[k]) for k in ("opens", "incs", "realized", "liqs", "edges"))

    risk = pl.concat([opens.select("accountId", "lev", "deposit", "ts"), incs.select("accountId", "lev", "deposit", "ts")])
    f_risk = risk.group_by("accountId").agg(
        ((pl.col("lev") * pl.col("deposit").abs()).sum() / pl.col("deposit").abs().sum().clip(1e-9)).alias("avg_lev"),
        pl.col("deposit").max().alias("max_deposit"),
    )
    f_real = realized.sort("ts").group_by("accountId").agg(
        pl.col("pnl").sum().alias("realized_pnl"),
        pl.len().alias("n_closes"),
        (pl.col("pnl") > 0).mean().alias("win_rate"),
        (pl.col("pnl").cum_sum().cum_max() - pl.col("pnl").cum_sum()).max().alias("max_dd"),
    )
    days = pl.concat([d.select("accountId", "ts") for d in (opens, incs, realized)]).with_columns((pl.col("ts") // DAY).alias("day"))
    f_days = days.group_by("accountId").agg(pl.col("day").n_unique().alias("active_days"), pl.col("ts").max().alias("last_ts"))
    f_liq = liqs.group_by("accountId").agg(pl.len().alias("liq_hist"))
    fees = pl.concat([
        opens.select("accountId", "fee"), incs.select("accountId", "fee"),
        edges.select(pl.col("maker").alias("accountId"), "fee"),
    ]).group_by("accountId").agg(pl.col("fee").sum().alias("fees"))

    # Counterparty concentration: volume with each counterparty, both directions.
    pair = pl.concat([
        edges.select(pl.col("maker").alias("a"), pl.col("taker").alias("b"), "notional"),
        edges.select(pl.col("taker").alias("a"), pl.col("maker").alias("b"), "notional"),
    ]).filter(pl.col("a") != pl.col("b")).group_by("a", "b").agg(pl.col("notional").sum())
    vol = pair.group_by("a").agg(pl.col("notional").sum().alias("volume"))
    top = pair.join(vol, on="a").with_columns((pl.col("notional") / pl.col("volume")).alias("share")).sort("share", descending=True).group_by("a").first()
    recip = _wash_clusters(pair, vol).join(top.select("a", pl.col("share").alias("top_cp_share")), on="a", how="left")
    recip = recip.select(pl.col("a").alias("accountId"), "volume", "top_cp_share", "wash_share", "wash_pair")

    f = (
        f_days.join(f_risk, on="accountId", how="left").join(f_real, on="accountId", how="left")
        .join(f_liq, on="accountId", how="left").join(fees, on="accountId", how="left").join(recip, on="accountId", how="left")
        .with_columns(
            pl.col("realized_pnl", "n_closes", "win_rate", "max_dd", "liq_hist", "fees", "volume", "top_cp_share", "wash_share").fill_null(0),
            pl.col("avg_lev").fill_null(1.0), pl.col("max_deposit").fill_null(0.0), pl.col("wash_pair").fill_null(False),
        )
        .with_columns(
            # PnL against strangers: discount the share of volume traded inside a wash cluster.
            pl.when(pl.col("wash_pair")).then(pl.col("realized_pnl") * (1 - pl.col("wash_share"))).otherwise(pl.col("realized_pnl")).alias("pnl_ext"),
            pl.col("max_deposit").clip(50.0).alias("capital"),
        )
        .with_columns((pl.col("pnl_ext") / pl.col("capital")).alias("ret_ext"), (pl.col("max_dd") / pl.col("capital")).alias("dd_ratio"))
    )
    return f


def score_margin_line(f: pl.DataFrame) -> pl.DataFrame:
    rank = lambda c: pl.col(c).rank("average") / pl.len()
    approve = (
        (pl.col("active_days") >= MIN_ACTIVE_DAYS) & (pl.col("n_closes") >= MIN_CLOSES) & (pl.col("liq_hist") == 0)
        & (pl.col("pnl_ext") > 0) & (pl.col("avg_lev") <= MAX_AVG_LEVERAGE) & (~pl.col("wash_pair"))
    )
    cont = rank("ret_ext") + rank("win_rate") - rank("avg_lev") - rank("dd_ratio") + 0.5 * rank("active_days") - 3.0 * (pl.col("liq_hist") > 0).cast(pl.Float64)
    return f.with_columns(approve.alias("ml_approve"), cont.alias("ml_score"))


def wilson(k: int, n: int, z: float = 1.96) -> list:
    """95% Wilson interval for a rate k/n."""
    if n == 0:
        return [float("nan"), float("nan")]
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [max(0.0, c - h), min(1.0, c + h)]


def fisher_less(a: int, b: int, c: int, d: int) -> float:
    """One-sided Fisher exact p-value that group 1 (a bad of a+b) has a lower bad rate than group 2
    (c bad of c+d)."""
    n1, n2, k = a + b, c + d, a + c
    total = math.comb(n1 + n2, k)
    return sum(math.comb(n1, i) * math.comb(n2, k - i) for i in range(0, a + 1) if 0 <= k - i <= n2) / total


def auc(score: np.ndarray, bad: np.ndarray) -> float:
    """Probability that a random good trader scores above a random bad one (0.5 = no signal)."""
    good_s, bad_s = score[~bad], score[bad]
    if len(good_s) == 0 or len(bad_s) == 0:
        return float("nan")
    order = np.argsort(np.concatenate([bad_s, good_s]), kind="mergesort")
    ranks = np.empty(len(order))
    ranks[order] = np.arange(1, len(order) + 1)
    # average ranks for ties
    allv = np.concatenate([bad_s, good_s])
    _, inv, counts = np.unique(allv, return_inverse=True, return_counts=True)
    sums = np.bincount(inv, weights=ranks)
    ranks = (sums / counts)[inv]
    r_good = ranks[len(bad_s):].sum()
    return float((r_good - len(good_s) * (len(good_s) + 1) / 2) / (len(good_s) * len(bad_s)))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--horizon-days", type=int, default=7)
    args = ap.parse_args()
    H = args.horizon_days * DAY
    to_ts = block_time()
    t = build_tables(to_ts)
    t0, t1 = float(to_ts([START_BLOCK])[0]), float(to_ts([END_BLOCK])[0])
    checkpoints = [t0 + d * DAY for d in range(14, 43, 7) if t0 + d * DAY + H <= t1]

    rng = np.random.default_rng(7)
    results, pooled = [], []
    for T in checkpoints:
        f = score_margin_line(features(t, T))
        recent = f.filter(pl.col("last_ts") >= T - 14 * DAY)  # applicants: traded in the last two weeks
        after = pl.concat([t[k].filter((pl.col("ts") >= T) & (pl.col("ts") < T + H)).select("accountId") for k in ("opens", "incs", "realized")]).unique()
        liq_after = t["liqs"].filter((pl.col("ts") >= T) & (pl.col("ts") < T + H)).select("accountId").unique().with_columns(pl.lit(True).alias("liquidated"))
        pop = recent.join(after, on="accountId", how="inner").join(liq_after, on="accountId", how="left").with_columns(pl.col("liquidated").fill_null(False))
        pop = pop.with_columns(((pl.col("active_days") >= MIN_ACTIVE_DAYS) & (pl.col("n_closes") >= MIN_CLOSES)).alias("exp_approve"))
        bad = pop["liquidated"].to_numpy()
        appr = pop["ml_approve"].to_numpy()
        exp = pop["exp_approve"].to_numpy()
        row = {
            "checkpoint": datetime.fromtimestamp(T, timezone.utc).date().isoformat(),
            "traders": pop.height,
            "liquidated": int(bad.sum()),
            "base_rate": float(bad.mean()) if len(bad) else float("nan"),
            "approved": int(appr.sum()),
            "approved_liq_rate": float(bad[appr].mean()) if appr.any() else float("nan"),
            "denied_liq_rate": float(bad[~appr].mean()) if (~appr).any() else float("nan"),
            "experience_only_approved": int(exp.sum()),
            "experience_only_liq_rate": float(bad[exp].mean()) if exp.any() else float("nan"),
            "auc_margin_line": auc(pop["ml_score"].to_numpy(), bad),
            "auc_volume": auc(pop["volume"].to_numpy(), bad),
            "auc_raw_pnl": auc(pop["realized_pnl"].to_numpy(), bad),
            "auc_random": auc(rng.random(pop.height), bad),
            "wash_pairs_flagged": int(pop["wash_pair"].sum()),
        }
        results.append(row)
        pooled.append(pop.select("accountId", "ml_score", "ml_approve", "exp_approve", "volume", "realized_pnl", "liquidated"))
        print(json.dumps(row), flush=True)

    P = pl.concat(pooled)
    bad = P["liquidated"].to_numpy()
    appr = P["ml_approve"].to_numpy()
    exp = P["exp_approve"].to_numpy()
    # Margin Line approvals versus experienced traders it denied: does the score add beyond experience?
    exp_denied = exp & ~appr
    a, b = int(bad[appr].sum()), int((~bad[appr]).sum())
    c, d = int(bad[exp_denied].sum()), int((~bad[exp_denied]).sum())
    summary_stats = {
        "approved_liq_rate_ci95": wilson(a, a + b),
        "experience_only_approved": int(exp.sum()),
        "experience_only_liq_rate": float(bad[exp].mean()),
        "experienced_but_denied": int(exp_denied.sum()),
        "experienced_but_denied_liq_rate": float(bad[exp_denied].mean()) if exp_denied.any() else None,
        "p_approved_safer_than_experienced_denied": fisher_less(a, b, c, d),
        "p_approved_safer_than_all_denied": fisher_less(a, b, int(bad[~appr].sum()), int((~bad[~appr]).sum())),
        "unique_traders": P["accountId"].n_unique(),
        "unique_approved_traders": P.filter(pl.col("ml_approve"))["accountId"].n_unique(),
    }
    summary = {
        "horizon_days": args.horizon_days,
        "window": [datetime.fromtimestamp(t0, timezone.utc).isoformat(), datetime.fromtimestamp(t1, timezone.utc).isoformat()],
        "trader_checkpoints": P.height,
        "liquidations": int(bad.sum()),
        "base_rate": float(bad.mean()),
        "approved": int(appr.sum()),
        "approved_liq_rate": float(bad[appr].mean()) if appr.any() else None,
        "denied_liq_rate": float(bad[~appr].mean()),
        **summary_stats,
        "auc_margin_line": auc(P["ml_score"].to_numpy(), bad),
        "auc_volume": auc(P["volume"].to_numpy(), bad),
        "auc_raw_pnl": auc(P["realized_pnl"].to_numpy(), bad),
        "auc_random": auc(rng.random(P.height), bad),
        "checkpoints": results,
        "rule": {"min_active_days": MIN_ACTIVE_DAYS, "min_closes": MIN_CLOSES, "max_avg_leverage": MAX_AVG_LEVERAGE, "wash_share": WASH_SHARE, "wash_edge_share": WASH_EDGE_SHARE},
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"report-h{args.horizon_days}.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != "checkpoints"}, indent=2))


if __name__ == "__main__":
    main()
