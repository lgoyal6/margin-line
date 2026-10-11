#!/usr/bin/env bash
# Pull any newly published history ranges, decode everything, and rerun the backtest at 7 and 14 days.
# Usage: data/refresh.sh   (needs gh auth and the analysis venv: uv venv .agent-work/venv && uv pip install -r data/requirements.txt)
set -euo pipefail
cd "$(dirname "$0")/.."
PY=.agent-work/venv/bin/python
mkdir -p data/raw/releases data/raw/history
gh release download data-perpl-raw --repo lgoyal6/margin-line --dir data/raw/releases --skip-existing
for t in data/raw/releases/*.tar; do
  marker="data/raw/releases/.$(basename "$t").unpacked"
  [ -f "$marker" ] && continue
  tar -xf "$t" -C data/raw/releases && mv data/raw/releases/perpl/*.jsonl.gz data/raw/history/ && rm -rf data/raw/releases/perpl
  touch "$marker"
done
$PY data/decode.py
$PY data/backtest.py --horizon-days 7
$PY data/backtest.py --horizon-days 14
