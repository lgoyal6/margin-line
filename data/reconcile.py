"""Reconcile the decoded Perpl history with Perpl's own mainnet state at the backtest's cutoff block.

Checks, all at block 112,140,000 (read-only calls to Monad mainnet):
1. Accounts: AccountCreated events == Exchange.numberOfAccounts().
2. Open interest: every position rebuilt from its latest position event, summed per market and side,
   == the long and short open interest Perpl reports for that market.

Usage: .agent-work/venv/bin/python data/reconcile.py [--rpc-url URL]
"""

import argparse
import json
import subprocess
from pathlib import Path

import polars as pl

HERE = Path(__file__).resolve().parent
EV = HERE / "derived" / "events"
OUT = HERE.parent / "docs" / "evidence" / "reconcile.json"
EXCHANGE = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F"
CUTOFF = 112_140_000
PERP_INFO = ("getPerpetualInfoV2(uint256)((string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,"
             "uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,"
             "uint256,uint256,uint256,uint256,uint256,bool,uint256))")


def cast_call(rpc: str, sig: str, *args) -> str:
    cmd = ["cast", "call", EXCHANGE, sig, *map(str, args), "--block", str(CUTOFF), "--rpc-url", rpc]
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def ev(name: str, *cols) -> pl.LazyFrame:
    return pl.scan_parquet(EV / f"{name}.parquet").filter(pl.col("block") <= CUTOFF).select("block", "log_index", *cols)


def positions() -> pl.DataFrame:
    """Lot and side of every (market, account) position after its latest event."""
    acct = ("perpId", "accountId", "positionType")
    frames = [ev(n, *acct, pl.col("lotLNS").alias("lot")) for n in ("PositionOpened", "PositionOpenedV2")]
    frames += [ev(n, *acct, pl.col("endLotLNS").alias("lot"))
               for n in ("PositionIncreased", "PositionIncreasedV2", "PositionDecreased", "PositionInverted", "PositionDeleveragedV2")]
    frames.append(ev("PositionClosed", *acct, pl.lit(0, pl.Int64).alias("lot")))
    frames.append(ev("PositionLiquidated", "perpId", pl.col("posAccountId").alias("accountId"), "positionType",
                     (pl.col("posLotLNS") - pl.col("liqLotLNS")).alias("lot")))
    allev = pl.concat([f.with_columns(pl.col("lot").cast(pl.Int64)) for f in frames], how="vertical_relaxed").collect()
    return allev.sort(["block", "log_index"]).group_by(["perpId", "accountId"]).last()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc-url", default="https://rpc.monad.xyz")
    rpc = ap.parse_args().rpc_url

    created = ev("AccountCreated", "id").collect()
    onchain_accounts = int(cast_call(rpc, "numberOfAccounts()(uint256)").split()[0])
    accounts = {"accountCreatedEvents": created.height, "maxAccountId": int(created["id"].max()),
                "numberOfAccountsOnchain": onchain_accounts, "match": created.height == onchain_accounts}

    pos = positions().filter(pl.col("lot") > 0)
    ours = pos.group_by(["perpId", "positionType"]).agg(pl.col("lot").sum().alias("lots"), pl.len().alias("positions"))
    markets = []
    for perp in sorted(set(pos["perpId"].to_list()) | {1, 10, 20, 31, 40, 50, 60, 70, 90, 100, 110}):
        fields = [f.strip().split(" ")[0] for f in cast_call(rpc, PERP_INFO, perp).strip("()").split(",")]
        name, long_oi, short_oi = fields[1].strip('"'), int(fields[17]), int(fields[18])

        def side(t):
            r = ours.filter((pl.col("perpId") == perp) & (pl.col("positionType") == t))
            return (int(r["lots"][0]), int(r["positions"][0])) if r.height else (0, 0)

        (ol, on), (os_, osn) = side(0), side(1)
        markets.append({"perpId": perp, "symbol": name, "longOnchain": long_oi, "longFromEvents": ol, "shortOnchain": short_oi,
                        "shortFromEvents": os_, "openPositions": on + osn, "match": ol == long_oi and os_ == short_oi})

    report = {"block": CUTOFF, "exchange": EXCHANGE, "accounts": accounts, "openInterest": markets,
              "pass": accounts["match"] and all(m["match"] for m in markets)}
    OUT.write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
