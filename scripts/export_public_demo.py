"""Bundle recorded risk evidence for the public Margin Line explorer.
The page reads these existing reports without connecting a wallet or RPC.
Hashes bind each displayed report to its source revision.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "seven.json": "docs/evidence/backtest-h7.json",
    "fourteen.json": "docs/evidence/backtest-h14.json",
    "stress.json": "e2e/evidence/worst-day/result.json",
}


def main():
    target = ROOT / "docs/public-demo/source"
    target.mkdir(parents=True, exist_ok=True)
    records = []
    for name, relative in SOURCES.items():
        raw = subprocess.check_output(["git", "show", f"HEAD:{relative}"], cwd=ROOT)
        source = ROOT / relative
        if source.read_bytes() != raw:
            raise ValueError(f"Uncommitted evidence cannot enter the public bundle: {relative}")
        shutil.copyfile(source, target / name)
        records.append({"file": name, "path": relative,
                        "sha256": hashlib.sha256(raw).hexdigest()})
    manifest = {"source_commit": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "reports": records}
    (target.parent / "evidence.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
