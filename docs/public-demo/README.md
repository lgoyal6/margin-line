# Public risk evidence explorer

Run `python3 scripts/export_public_demo.py` from the repository root, then serve
this directory as a static site. The exporter refuses uncommitted evidence.
The browser checks each report's SHA-256 before displaying it.

The controls compare saved 7-day and 14-day screening results, individual
checkpoints, and four local-fork keeper scenarios. No wallet, RPC, contract,
account or exchange connection runs in the page. The full interactive contract
application remains in `app/` and needs its documented local chain.

Backtest liquidation rates are historical associations with repeated traders.
The fork experiment uses a controlled book and fixed replay conditions. Neither
establishes future lending returns or production safety.
