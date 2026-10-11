"""Decode raw Perpl event chunks into one Parquet table per event type.

Input: gzip JSONL chunks written by data/perpl_backfill.py (data/raw/history and data/raw/perpl).
Output: data/derived/events/<EventName>.parquet, deduplicated on (block, log_index), sorted by block.

Every field of the events we keep is a static ABI type and none is indexed, so each field is one
32-byte word of `data` in declaration order. The definitions come from Perpl's published Exchange ABI
(data/perpl_events_abi.json).

Usage: .agent-work/venv/bin/python data/decode.py
"""

import gzip
import json
import os
import sys
from collections import defaultdict
from multiprocessing import Pool
from pathlib import Path

import polars as pl

HERE = Path(__file__).resolve().parent
SOURCES = [HERE / "raw" / "history", HERE / "raw" / "perpl"]
OUT = HERE / "derived" / "events"

ABI = json.loads((HERE / "perpl_events_abi.json").read_text())
TOPICS = json.loads((HERE / "perpl_topics.json").read_text())
EVENTS = {TOPICS[e["name"]]: e for e in ABI}


def _field(word: str, typ: str):
    if typ.startswith("uint"):
        return int(word, 16)
    if typ.startswith("int"):
        v = int(word, 16)  # ABI sign-extends every intN to 256 bits
        return v - (1 << 256) if v >> 255 else v
    if typ == "bool":
        return int(word, 16) != 0
    if typ == "address":
        return "0x" + word[24:]
    raise ValueError(f"unsupported type {typ}")


def decode_file(path: str) -> dict:
    rows = defaultdict(list)
    with gzip.open(path, "rt") as f:
        for line in f:
            log = json.loads(line)
            ev = EVENTS.get(log["topic0"])
            if ev is None:
                continue
            data = log["data"][2:]
            row = {"block": log["block_number"], "log_index": log["log_index"], "tx": log["transaction_hash"]}
            for i, inp in enumerate(ev["inputs"]):
                row[inp["name"]] = _field(data[64 * i : 64 * (i + 1)], inp["type"])
            rows[ev["name"]].append(row)
    return rows


def _frame(rows: list) -> pl.DataFrame:
    """Integers that fit stay Int64; any column with a value outside Int64 is stored as Float64 and
    reported, so nothing is silently truncated."""
    cols = rows[0].keys()
    data = {}
    for c in cols:
        vals = [r[c] for r in rows]
        if isinstance(vals[0], int) and not isinstance(vals[0], bool):
            if any(v > 2**63 - 1 or v < -(2**63) for v in vals):
                print(f"    note: column {c} exceeds Int64, stored as Float64", flush=True)
                data[c] = pl.Series(c, [float(v) for v in vals], dtype=pl.Float64)
            else:
                data[c] = pl.Series(c, vals, dtype=pl.Int64)
        else:
            data[c] = pl.Series(c, vals)
    return pl.DataFrame(data)


def main() -> None:
    files = [str(p) for src in SOURCES if src.exists() for p in sorted(src.glob("*.jsonl.gz"))]
    print(f"{len(files)} chunks", flush=True)
    merged = defaultdict(list)
    with Pool(os.cpu_count()) as pool:
        for i, rows in enumerate(pool.imap_unordered(decode_file, files, chunksize=8)):
            for name, rs in rows.items():
                merged[name].extend(rs)
            if (i + 1) % 500 == 0:
                print(f"  decoded {i + 1}/{len(files)}", flush=True)

    OUT.mkdir(parents=True, exist_ok=True)
    for name, rows in sorted(merged.items()):
        df = _frame(rows).unique(subset=["block", "log_index"]).sort(["block", "log_index"])
        df.write_parquet(OUT / f"{name}.parquet")
        print(f"{name:32} {df.height:>10,}  blocks {df['block'].min()} -> {df['block'].max()}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
