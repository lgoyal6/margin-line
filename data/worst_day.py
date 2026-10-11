"""Find the worst real day in Perpl's mainnet history and extract what e2e/src/worst-day.ts replays.

Worst day: the UTC day with the most PositionLiquidated events. Also reports the day with the largest
BTC move (from PositionClosed prices). For the worst day it writes BTC's minute path (median maker fill
price per minute, so single wick fills do not set the mark) and the approved traders whose lines the
replay opens, taken from a published score epoch.

Mainnet BTC is perp 1 (1 price decimal); the testnet fork's BTC is perp 16.
Usage: .agent-work/venv/bin/python data/worst_day.py <epoch.json>
"""

import datetime as dt
import json
import sys
from pathlib import Path

import numpy as np
import polars as pl

HERE = Path(__file__).resolve().parent
EV = HERE / "derived" / "events"
OUT = HERE.parent / "e2e" / "evidence" / "worst-day" / "day.json"
BTC = 1
PRICE_SCALE = 10  # perp 1 prices have 1 decimal
MIN_LINE = 100  # Perpl's minimum account open, AUSD: deposit + principal must reach it
LIMIT_QUANTILES = (0.25, 0.5, 0.75, 0.9, 0.95, 1.0)

pts = json.loads((HERE / "block_timestamps.json").read_text())
B = np.array([p[0] for p in pts], dtype=np.float64)
T = np.array([p[1] for p in pts], dtype=np.float64)


def with_day(df: pl.DataFrame) -> pl.DataFrame:
    ts = pl.Series(np.interp(df["block"].to_numpy(), B, T)).cast(pl.Int64)
    return df.with_columns(pl.from_epoch(ts).alias("ts")).with_columns(pl.col("ts").dt.date().alias("day"))


def main(epoch_path: str) -> None:
    liq = with_day(pl.read_parquet(EV / "PositionLiquidated.parquet", columns=["block", "perpId", "posAccountId"]))
    by_day = (liq.group_by("day").agg(pl.len().alias("liquidations"), (pl.col("perpId") == BTC).sum().alias("btcLiquidations"),
                                     pl.col("posAccountId").n_unique().alias("accounts"))
              .sort(["liquidations", "day"], descending=[True, False]))
    worst = by_day["day"][0]

    closes = with_day(pl.scan_parquet(EV / "PositionClosed.parquet").filter(pl.col("perpId") == BTC)
                      .select("block", "pricePNS").collect()).sort("block")
    moves = (closes.group_by("day").agg((pl.col("pricePNS").first() / PRICE_SCALE).alias("open"),
                                         (pl.col("pricePNS").last() / PRICE_SCALE).alias("close"),
                                         (pl.col("pricePNS").max() / PRICE_SCALE).alias("high"),
                                         (pl.col("pricePNS").min() / PRICE_SCALE).alias("low"), pl.len().alias("closes"))
             .with_columns(((pl.col("close") / pl.col("open") - 1) * 100).round(2).alias("openToClosePct"),
                           ((pl.col("high") / pl.col("low") - 1) * 100).round(2).alias("lowToHighPct")))
    biggest_move = moves.sort(pl.col("openToClosePct").abs(), descending=True).head(5)
    widest_range = moves.sort("lowToHighPct", descending=True).head(5)

    # Minute path of the worst day from maker fills (every fill has a maker; perpId is on the maker event).
    start = dt.datetime.combine(worst, dt.time(), dt.timezone.utc).timestamp()
    lo, hi = int(np.interp(start, T, B)) - 10, int(np.interp(start + 86_400, T, B)) + 10
    fills = pl.concat([
        pl.scan_parquet(EV / f"{n}.parquet").filter((pl.col("perpId") == BTC) & pl.col("block").is_between(lo, hi))
        .select("block", "pricePNS") for n in ("MakerOrderFilled", "MakerOrderFilledV2")
    ]).collect()
    fills = with_day(fills).filter(pl.col("day") == worst).sort("ts")
    minutes = fills.group_by_dynamic("ts", every="1m").agg((pl.col("pricePNS").median() / PRICE_SCALE).alias("price"), pl.len().alias("fills"))
    grid = pl.DataFrame({"ts": pl.datetime_range(dt.datetime.combine(worst, dt.time()), dt.datetime.combine(worst, dt.time(23, 59)), "1m", eager=True)})
    path = grid.join(minutes.with_columns(pl.col("ts").dt.replace_time_zone(None)), on="ts", how="left").with_columns(
        pl.col("price").forward_fill().backward_fill(), pl.col("fills").fill_null(0))

    # Approved traders from the epoch, at spread-out credit limits, alternating long and short.
    epoch = json.loads(Path(epoch_path).read_text())
    approved = sorted((l for l in epoch["leaves"] if l["limit"] > 0 and 3 * l["features"]["maxDepositMicro"] >= MIN_LINE * 10**6),
                      key=lambda l: (l["limit"], l["perplAccount"]))
    picks = []
    for i, q in enumerate(LIMIT_QUANTILES):
        l = approved[min(len(approved) - 1, int(q * (len(approved) - 1)))]
        picks.append({"perplAccount": l["perplAccount"], "limitMicro": l["limit"], "maxDepositMicro": l["features"]["maxDepositMicro"],
                      "avgLevBps": l["features"]["avgLevBps"], "aprBps": l["aprBps"], "side": "long" if i % 2 == 0 else "short", "limitQuantile": q})

    report = {
        "source": "Perpl mainnet events, data/derived/events (blocks 54,972,991 to 112,140,000)",
        "worstDay": str(worst),
        "liquidationsByDay": [{**r, "day": str(r["day"])} for r in by_day.head(10).to_dicts()],
        "biggestBtcMoveOpenToClose": [{**r, "day": str(r["day"])} for r in biggest_move.to_dicts()],
        "widestBtcRangeLowToHigh": [{**r, "day": str(r["day"])} for r in widest_range.to_dicts()],
        "path": {
            "perpIdMainnet": BTC, "granularity": "1 minute, median maker fill price; minutes without fills carry the last price",
            "fills": fills.height, "minutesWithFills": int((path["fills"] > 0).sum()),
            "open": path["price"][0], "close": path["price"][-1], "low": path["price"].min(), "high": path["price"].max(),
            "prices": [round(p, 1) for p in path["price"].to_list()],
        },
        "epoch": {"file": Path(epoch_path).name, "epoch": epoch["epoch"], "approved": sum(1 for l in epoch["leaves"] if l["limit"] > 0)},
        "traders": picks,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("path", "liquidationsByDay")} | {"liquidationsTop3": report["liquidationsByDay"][:3],
                      "path": {k: v for k, v in report["path"].items() if k != "prices"}}, indent=1, default=str))


if __name__ == "__main__":
    main(sys.argv[1])
