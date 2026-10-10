"""Backfill Perpl Exchange events on Monad mainnet from Envio HyperSync.

Downloads only the events the credit model needs (fills, position lifecycle, liquidations,
deleverages, unwinds, collateral moves, funding) and writes them as gzip JSONL chunks.
Resumable: progress is checkpointed after every chunk, so rerunning continues where it stopped.

Usage:
    ENVIO_API_TOKEN=... python3 data/perpl_backfill.py [--from-block N] [--to-block N]

Monad note: public RPC caps eth_getLogs at 100 blocks per call, which is why history comes from
HyperSync. Blocks past the safe head are left for the live indexer.
"""

import argparse
import gzip
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HYPERSYNC = "https://monad.hypersync.xyz"
EXCHANGE = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F"
FIRST_BLOCK = 54_972_991  # first AccountCreated on Perpl mainnet
SAFE_LAG = 10  # stay behind the head; finalized history only
MIN_INTERVAL_S = 4.2  # free plan: 15 requests per minute

HERE = Path(__file__).resolve().parent
OUT = HERE / "raw" / "perpl"
TOPICS_FILE = HERE / "perpl_topics.json"

FIELDS = ["block_number", "transaction_hash", "log_index", "topic0", "topic1", "topic2", "topic3", "data"]


def post(path: str, body: dict | None, token: str) -> dict:
    req = urllib.request.Request(
        HYPERSYNC + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept-Encoding": "gzip",  # about 19x less transfer
        },
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        raw = resp.read()
        if resp.headers.get("Content-Encoding") == "gzip":
            raw = gzip.GzipFile(fileobj=io.BytesIO(raw)).read()
        return json.loads(raw)


def query_with_retry(body: dict, token: str) -> dict:
    delay = 5.0
    for attempt in range(8):
        try:
            return post("/query", body, token)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504):
                raise
            print(f"  http {e.code}, retrying in {delay:.0f}s", flush=True)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            print(f"  network error {e}, retrying in {delay:.0f}s", flush=True)
        time.sleep(delay)
        delay = min(delay * 2, 120)
    raise RuntimeError("HyperSync query kept failing")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--from-block", type=int, default=FIRST_BLOCK)
    parser.add_argument("--to-block", type=int, default=None)
    args = parser.parse_args()

    token = os.environ.get("ENVIO_API_TOKEN")
    if not token:
        sys.exit("ENVIO_API_TOKEN is not set")

    topics = list(json.loads(TOPICS_FILE.read_text()).values())
    OUT.mkdir(parents=True, exist_ok=True)
    head = int(post("/height", None, token)["height"]) - SAFE_LAG
    to_block = min(args.to_block or head, head)
    # One checkpoint per requested range, so recent and older history can be filled independently.
    checkpoint = OUT / f"checkpoint-{args.from_block}-{args.to_block or 'head'}.json"
    state = (
        json.loads(checkpoint.read_text())
        if checkpoint.exists()
        else {"next_block": args.from_block, "chunks": 0, "logs": 0}
    )
    print(f"from {state['next_block']} to {to_block} ({to_block - state['next_block']:,} blocks)", flush=True)

    last = 0.0
    while state["next_block"] < to_block:
        wait = MIN_INTERVAL_S - (time.monotonic() - last)
        if wait > 0:
            time.sleep(wait)
        last = time.monotonic()

        start = state["next_block"]
        resp = query_with_retry(
            {
                "from_block": start,
                "to_block": to_block,
                "max_num_logs": 50_000,
                "logs": [{"address": [EXCHANGE], "topics": [topics]}],
                "field_selection": {"log": FIELDS},
            },
            token,
        )
        logs = [log for batch in resp.get("data", []) for log in batch.get("logs", [])]
        end = int(resp["next_block"])
        if end <= start:
            raise RuntimeError(f"HyperSync made no progress at block {start}")

        chunk = OUT / f"{start:012d}-{end:012d}.jsonl.gz"
        tmp = chunk.with_suffix(".tmp")
        with gzip.open(tmp, "wt") as f:
            for log in logs:
                f.write(json.dumps(log, separators=(",", ":")) + "\n")
        tmp.replace(chunk)

        state.update(next_block=end, chunks=state["chunks"] + 1, logs=state["logs"] + len(logs))
        checkpoint.write_text(json.dumps(state))
        done = (end - args.from_block) / (to_block - args.from_block)
        print(f"{done:6.1%}  blocks {start}->{end}  +{len(logs):,} logs  total {state['logs']:,}", flush=True)

    print(f"done: {state['logs']:,} logs in {state['chunks']} chunks up to block {state['next_block']}", flush=True)


if __name__ == "__main__":
    main()
