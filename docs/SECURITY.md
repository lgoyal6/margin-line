# Margin Line security model

This document describes what the system protects, who can act, and which assumptions remain outside
the contracts. The local app and fork are development surfaces. They never represent a live approval.

## Assets

- AUSD held by the senior vault, junior vault, reserve, and open credit lines.
- Lender share balances and FIFO withdrawal requests.
- Borrower deposits, Perpl collateral, positions, and realized profit.
- Passkey registrations, recovery guardians, session keys, and history links.
- Curator limits, circuit-breaker state, underwriter approvals, and keeper bounties.

## Actors and trust assumptions

- Borrowers can trade through their own line, but cannot withdraw borrowed collateral.
- Lenders can deposit, withdraw when liquidity permits, and request a queued withdrawal.
- The underwriter decides eligibility and limit. A compromised key can approve bad borrowers, so it is
  a guarded operational key and can be revoked by the curator.
- The curator controls market parameters. Loosening uses a public timelock and a guardian veto.
- The guardian can veto pending loosening and resolve identity recovery or history-link disputes.
- Keepers are permissionless and economically motivated. A keeper may freeze, unwind, and settle, but
  cannot take pool funds beyond the configured bounty.
- Perpl and AUSD are external dependencies. The contracts cannot correct a malicious venue or token.

## Attack list and coverage

| Attack or failure | Mitigation | Test coverage |
| --- | --- | --- |
| Borrower exceeds approval or deposit leverage | Approval, concentration, and deposit checks | `test/unit/CreditLine.t.sol` (open tests), `test/unit/Caps.t.sol` |
| Borrowed funds are withdrawn | CreditLine owns the Perpl account, nobody is an operator, sweep needs health and a passkey | `test/unit/CreditLine.t.sol`, `test/fork/CreditLineFork.t.sol`, invariant "only the line controls its account" |
| Profit swept against a stale or invalid Perpl price | Sweep requires a valid mark no older than the guard allows for every open position | `test_sweep_refusesStaleMarkWithOpenPosition`, `test_sweep_refusesInvalidMarkWithOpenPosition` |
| Session key extracts money | Session keys can only trade, within per-order and total caps | `test/unit/Sessions.t.sol`, invariant "session keys never extract" |
| Unhealthy line remains open | Permissionless freeze, unwind, settlement, and bounty | `test/unit/Enforcement.t.sol`, invariant "unhealthy lines can always be frozen", `e2e/src/keeper-liveness.ts` |
| Loss is allocated out of order | Reserve, junior, then senior waterfall | `test/unit/CreditPool.t.sol` (hand calculations + fuzz), invariant "senior protected by junior" |
| Queue bypass or double withdrawal | FIFO queue; instant withdrawals cannot use liquidity owed to the queue | `test/unit/CreditPool.t.sol`, invariant "vaults hold no cash and queue balances" |
| First-depositor share inflation | Virtual-share offset; donations do not move tranche books | `test_inflationAttackIsUnprofitable` |
| Curator loosens a rule immediately | Instant path accepts only tightening; everything else waits out the timelock; guardian veto | `test/unit/Curator.t.sol` |
| Fake score root, or a root nobody can dispute | Publisher-only proposals with a bond; trustless leaf-consistency challenge; bonded disputes resolved instantly by the guardian; leaves bound to chain and oracle | `test/unit/ScoreOracle.t.sol`, `test/unit/ScoreManager.t.sol` |
| Wash trading inflates a score | Cluster detection (pairs and rings), profit discounted by inside share | `scorer/test_wash_ring.py` |
| Venue, oracle, or insurance-fund failure | Circuit breaker blocks new risk; never blocks closing, repaying, freezing or settling | `test/unit/Enforcement.t.sol` |
| Passkey replay or recovery abuse | Challenge bound to user, consumer, action, nonce and chain; guardian recovery with delay | `test/unit/IdentityRegistry.t.sol`, `e2e/src/run.ts` |
| History-link impersonation or replay | EIP-712 controller proof and nonce; one account maps to one borrower | `test/unit/HistoryLinkRegistry.t.sol` |
| Trade outside allowed market or price band | IOC-only guard, allowlist, leverage, price band, stale-mark and exposure caps | `test/unit/CreditLine.t.sol`, `test/unit/Caps.t.sol` |
| Reentrancy during accounting callbacks | `nonReentrant` on every state-changing entry point; only trusted external callees | unit and invariant suites; Slither triage below |

## Static analysis (Slither 0.11.3)

Run: `uvx --from slither-analyzer==0.11.3 slither . --filter-paths "lib/|test/|script/" --exclude-informational --exclude-optimization`

No high-severity findings. Every medium and low finding in `src/`, triaged:

| Finding | Count | Verdict |
| --- | --- | --- |
| unused-return: `getPositionV2` validity flag ignored | 4 | **Fixed one real issue.** Sweep now requires a valid, fresh mark for every open position (failing tests first, above). `equity()` and `_hasOpenPositions()` still read positions without the flag: freezing and settlement must keep working when Perpl's mark is unavailable, and opening risk already requires a fresh mark through TradeGuard. |
| unused-return: other tuple fields of `getExchangeInfo`, `getPositionV2`, `latestRoundData` | 7 | Accepted: only the fields used are needed (collateral decimals; position; answer and update time, with staleness checked via `updatedAt`). |
| reentrancy-no-eth / reentrancy-benign / reentrancy-events in CreditLine, MarketFactory, RiskCurator | 12 | Accepted: every state-changing CreditLine entry point is `nonReentrant` and gated by its state machine; the external callees are Perpl's DelegatedAccount (owned by the line), AUSD and the protocol's own pool and manager. MarketFactory and RiskCurator call only contracts they deployed or own. |
| incorrect-equality (`== 0` checks) | 7 | Accepted: deliberate zero checks (empty pool, zero debt, unset timelock entries, empty key slots), not balance equality against values an attacker can nudge. |
| divide-before-multiply in `CircuitBreaker.marketStatus` | 1 | Accepted: the open-interest notional is rounded down by under one micro-AUSD before the insurance comparison; negligible against any meaningful threshold. |
| uninitialized-local (`bounty`, `o`) | 2 | Accepted: intentionally zero-initialized (no bounty unless conditions hold; order struct filled field by field). |
| missing-zero-check | 9 | Accepted: owner- or timelock-gated setters. `setUnderwriter(0)` is the intended way to revoke the underwriter (`RiskCurator.revokeUnderwriter`). |
| events-maths in ScoreOracle setters | 2 | **Fixed:** `ChallengeWindowSet` and `MaxEpochAgeSet` events added, so a watcher sees every rule change. |
| calls-loop | 31 | Accepted: loops are bounded by `TradeGuard.MAX_MARKETS` (8) or by caller-chosen batch sizes (`processQueue(maxRequests)`). |
| timestamp | 22 | Accepted: timestamps gate timelocks, challenge windows, approvals and interest; a validator's few seconds of drift cannot change an outcome that matters. |

## Static analysis (Aderyn 0.6.8)

Run: `npx -y @cyfrin/aderyn@0.6.8 . --src src`

| Finding | Count | Verdict |
| --- | --- | --- |
| High: ETH transferred without address checks (`ScoreOracle.claim`) | 1 | Accepted: pays the caller its own credited balance; pull payment by design. |
| High: state change after external call | 16 | Accepted: same analysis as Slither's reentrancy findings. TrancheVault and CreditLine entry points are `nonReentrant`; CreditPool.settle's only prior call is a view on the protocol's own manager; MarketFactory's calls go to contracts it just deployed. |
| State change without event | 8 | **Fixed:** events added for `RiskCurator` timelock and guardian changes and oracle wiring, `ScoreOracle.reclaimChallenge`, and `CreditManager`'s one-time wiring. |
| Unsafe ERC20 operation / unchecked return | 2 | False positives: `IdentityRegistry.approve` (a passkey check, not an ERC-20 approval) and `TradeGuard.requireFreshMark`, which works by reverting. |
| Local variable shadows state variable | 1 | False positive: `Epoch.publisher` is a struct field. |
| Unused state variable (`TradeGuard.CLOSE_LONG`) | 1 | Pre-existing unused constant, left as documentation of the order-type enum. |
| Centralization risk, literals, numeric literals, loop patterns, public-not-used-internally | 89 | Accepted: owner powers are behind RiskCurator's timelock and guardian; the rest is style. |

## Operational boundary

Every Slither finding above has either a failing test and a fix, or an accepted-risk entry with its
reason. Runbooks for operating the market are in `docs/RUNBOOKS.md`.
