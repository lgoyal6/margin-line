# Margin Line

**Credit for traders who have earned it, on Monad.**

Lenders deposit dollars (AUSD) into a pool. A trader with a good track record on Perpl, Monad's onchain
perpetuals exchange, gets a credit line: their own deposit plus borrowed money go into a Perpl account
that a Margin Line contract owns. The trader can trade it on Perpl's real order book but can never
withdraw the borrowed money. If a line gets unhealthy, anyone can freeze it (and earn a bounty), close
its positions and settle it: lenders are repaid first, from the trader's deposit.

The credit limit comes from the trader's own Perpl history, scored offchain, published onchain as a
Merkle root, and open to challenge for a day before it counts.

Built for Monad Metropolis, Track 01 (Onchain Finance & Trading): undercollateralised lending priced on
onchain credit history.

## What is proven, and where

| Claim | Result | Evidence |
|---|---|---|
| A contract can own a Perpl account, trade it, and stop the trader withdrawing | Fork tests on testnet and mainnet, live testnet transactions | `test/phase0/`, `docs/DESIGN.md` |
| The score predicts who blows up | All of Perpl's history (Feb 12 to Oct 9, 2026, about 70M events): approved traders were liquidated within 7 days 3.8% of the time against 12.7% for denied traders; AUC 0.66; Fisher p = 4e-14 | `data/backtest.py`, `docs/evidence/backtest-h7.json` |
| Our copy of Perpl's history is complete | At block 112,140,000: 5,444 accounts = Perpl's `numberOfAccounts()`, and open interest rebuilt from events equals Perpl's in all 11 markets | `data/reconcile.py`, `docs/evidence/reconcile.json` |
| Lenders survive the worst real day | Aug 19, 2026 (249 liquidations, BTC +7.4%) replayed minute by minute on a fork against real-sized lines: zero pool loss with the keeper running, even at the market's maximum credit; with the keeper offline all day, $62 lost on one line, taken from the reserve then the junior tranche, senior untouched | `e2e/src/worst-day.ts`, `e2e/evidence/worst-day/` |
| Unhealthy lines are frozen at once | An independent keeper froze a live testnet line in the very next block, 3 runs out of 3, by deciding from logs Monad pushes with each proposed block, without a read | `keeper/src/keeper.ts`, `e2e/evidence/keeper-liveness-fast-path-*.json` |
| Scores are verifiable onchain | Score epoch 2 (5,257 Perpl accounts, 108 approved) finalized on testnet after an unchallenged one-day window; proofs verify, a tampered limit fails. Epoch 1 was retired live through a bonded dispute | `scorer/`, `src/ScoreOracle.sol` |
| Wash trading does not buy credit | Pairs and 3- and 5-account rings score zero; market-maker clients stay approved | `scorer/test_wash_ring.py` |
| A newcomer can use it unaided | Through the UI only, on live testnet: passkey account, credit line, session key, long on Perpl, profit sweep, close, lend | `e2e/src/newcomer.ts`, `e2e/evidence/newcomer-testnet/` |
| The contracts hold their invariants | 141 unit tests; 11 invariants over 3,000 runs x 128 calls; Slither and Aderyn findings fixed or explained | `test/`, `docs/SECURITY.md` |

## How it works

- **Pool and tranches** (`src/CreditPool.sol`, `src/TrancheVault.sol`): senior and junior ERC-4626
  vaults and a reserve. Interest pays the reserve, then senior's 8% target, then junior. Losses hit the
  reserve, then junior, then senior. Junior stays at least 20% of lender capital; withdrawals beyond idle
  cash wait in a first-in, first-out queue.
- **Credit lines** (`src/CreditLine.sol`, `src/CreditManager.sol`): one clone per borrower owning a
  Perpl account. Trades pass a guard (`src/TradeGuard.sol`): allowed markets, immediate-or-cancel only,
  leverage cap, price band around Perpl's mark, per-line exposure cap. Profit sweeps and closing need
  the trader's passkey.
- **Scores** (`scorer/`, `src/ScoreRules.sol`, `src/ScoreOracle.sol`): one Merkle leaf per scored Perpl
  account. A leaf whose limit does not follow from its own inputs is rejected by the contract itself;
  a leaf whose inputs disagree with chain data goes to a bonded challenge the guardian rules on.
- **Identity** (`src/IdentityRegistry.sol`): passkeys (P-256 / WebAuthn via Monad's precompile), session
  keys with budgets, guardian recovery. No seed phrase, no browser extension.
- **Enforcement** (`keeper/`, `src/CircuitBreaker.sol`, `monitor/`): permissionless freeze with a bounty,
  a circuit breaker that only ever blocks new risk, and a monitor whose seven alerts have each been
  fired by a deliberate failure.
- **Curation** (`src/RiskCurator.sol`, `src/RiskLens.sol`): rules can tighten instantly; loosening waits
  in a public timelock the guardian can veto. RiskLens stress-tests every open line for a price shock.

Full design and per-phase evidence: [docs/DESIGN.md](docs/DESIGN.md). Threat model: [docs/SECURITY.md](docs/SECURITY.md).
Runbooks: [docs/RUNBOOKS.md](docs/RUNBOOKS.md). Apps: [docs/APP.md](docs/APP.md).

## Live on Monad testnet

Addresses: [`deployments/monad-testnet.json`](deployments/monad-testnet.json) (full system deployed
through `MarketFactory`, BTC market on Perpl's testnet exchange, pool seeded with $10,000).

Known limit: scores come from Perpl's **mainnet** history, and a mainnet Perpl account cannot be linked
to a wallet on testnet, so testnet lines open through the underwriter path, labeled in the app as a
demo approval. The scored path is covered by unit and invariant tests.

## Run it

```bash
# Contracts (Foundry 1.8+)
forge build
forge test --no-match-path "test/{fork,invariant,phase0}/*"      # unit
forge test --match-path "test/invariant/*"                       # invariants
forge test --match-path "test/{fork,phase0}/*" --fork-url https://testnet-rpc.monad.xyz

# App against a local fork of testnet, or against live testnet
app/scripts/local-chain.sh && npm --prefix app run dev -- --port 5180
VITE_RPC_URL=https://testnet-rpc.monad.xyz npm --prefix app run dev -- --port 5181

# Keeper (permissionless; pushes over WebSocket)
cd keeper && npm install && KEEPER_KEY=0x... npm start

# Worst-day replay on a fresh fork
app/scripts/local-chain.sh && node --experimental-strip-types e2e/src/worst-day.ts
```

Perpl's API is geo-blocked from the US, so everything here reads Perpl's contracts directly; full history
was downloaded with Envio HyperSync (`data/perpl_backfill.py`, `.github/workflows/perpl-backfill.yml`).

AI coding tools (Claude Code) were used to write this project.
