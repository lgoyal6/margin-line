# Margin Line: design and build plan

The credit layer for onchain traders. Lenders fund proven traders on Perpl, Monad's onchain perpetuals
exchange. Borrowed money sits in a Perpl account that the protocol owns, so the trader can trade it but
can never withdraw it. The credit limit comes from the trader's verified record against real
counterparties.

## Principles

1. **Real venue, real data.** Trades run on Perpl's real order book and scores come from real mainnet
   history. No mock exchange, no mock oracle.
2. **Enforced onchain.** Custody, limits, freezes and repayment are contract logic. Offchain components
   are verifiable and never trusted blindly.
3. **The lender's worst case is the principal it lent.** Every design choice protects this.
4. **Built for Monad specifically:** its gas, reserve-balance, finality, storage and passkey semantics.
5. **Every number is checkable** by re-running the chain read behind it.

## Verified foundations (Phase 0)

| Claim | Evidence |
|---|---|
| A contract can own a Perpl trading account | `test/phase0/PerplBoundary.t.sol`, `test_contractOwnsPerplAccount`, on forks of Monad testnet and mainnet |
| That contract can open and close positions on Perpl's real order book through the owner path | `test_tradesOnRealOrderBookThroughOwnerPath` |
| The trader cannot withdraw or trade around the protocol | `test_traderCannotWithdrawDirectly`, `test_traderCannotTradeAroundTheHarness` |
| Withdrawals land only at the owning contract | `test_ownerWithdrawalReturnsFundsToOwner` |

Run: `forge test --match-path test/phase0/PerplBoundary.t.sol --fork-url https://testnet-rpc.monad.xyz`
(or `https://rpc.monad.xyz`). Foundry 1.8+ selects its Monad EVM only for CLI forks.

### Live on Monad testnet (`script/Phase0Live.s.sol`)

Owner contract `0xF3a3E28476E03f0925Ce581Ab42184bf20500917` created DelegatedAccount
`0x4d0b85134CDdf114eEfCF2Cb5667320417E4b9b6` (Perpl account 1048). Afterwards `owner()` returns the
owner contract and the Perpl account holds 149.91 AUSD with no open position.

| Step | Gas used | Transaction |
|---|---|---|
| AUSD faucet drip | 169,780 | `0xbb155c94065ebca6bd4c8b04a475a51412953571a46d5532cd7f365cfb054387` |
| Deploy owner contract, create DelegatedAccount | 1,353,041 | `0xc3601ad5a0df45df0d083f999641b51605a506c69e2933ccf6f75d282decde24` |
| Fund owner contract | 94,793 | `0x058969b12c34b395571d319f59a62c87d380dbb8cc465cad572a0812a30dd1fd` |
| Open Perpl account with 200 AUSD | 434,294 | `0x453c467400e3b93ec0ca9f157abad7902590cf9140353e000ba16ce2a345d196` |
| Open 0.001 BTC long on Perpl's book | 510,226 | `0x14d4e9925447069faaaafc2b3d218e5e4203f74b6e153304c15b230752310e73` |
| Close it reduce-only | 421,179 | `0x084d9540615edf41705e70dca8f3c4a6b3997c427e0577c80a44a4d7dea44948` |
| Withdraw 50 AUSD to the owner contract | 348,514 | `0x4e1447fdc71903936a60f32975bbbd4043cacc220623e6bf7c7cc55d09a03747` |

**Design consequence:** the trader is never added as a DelegatedAccount operator. Perpl's default
operator allowlist includes `execOrder`, `execOrders`, `buyLiquidations`, `allowOrderForwarding` and
collateral moves (`lib/delegated-account/src/DelegatedAccount.sol`, `initialize`). Leaving the operator
unset removes that whole surface: the only path to the Perpl account is `CreditLine`, which applies
our checks and then forwards as owner.

Deployments used (PerplFoundation/delegated-account README, checked onchain):

| | Testnet (10143) | Mainnet (143) |
|---|---|---|
| Exchange | `0x1964C32f0bE608E7D29302AFF5E61268E72080cc` | `0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` |
| DelegatedAccountFactory | `0xf42548Ccb3300Bc76c35dc2D347416db2E8d7209` | `0xc535276e3e446e4F28D95ed27cCd5c32e4C8907a` |
| AUSD collateral (6 decimals) | `0xa9012a055bd4e0eDfF8Ce09f960291C09D5322dC` | `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a` |
| BTC perp id | 16 | 1 |
| Minimum account open | 100 AUSD | 10 AUSD |
| AUSD faucet | Agora `0xd236c18D274E54FAccC3dd9DDA4b27965a73ee6C` (10,000 per drip, 60 s cooldown, 100,000 cap) | n/a |

## Architecture

```
                         ┌──────────── CLIENTS ────────────┐
                         │ Trader app · Lender app ·        │
                         │ Curator console · Public explorer│
                         └──────┬───────────────────┬───────┘
                   passkey (Mera, P256)        signed reads
                                │                   │
 ┌──────────── ONCHAIN (Monad) ─▼───────────────────▼───────────────┐
 │ IdentityRegistry · HistoryLinkRegistry · ScoreRoot (epochs)      │
 │ CreditPool (senior/junior) · CuratorVaults · RiskParams          │
 │ CreditLine (one per borrower) ──owns──► Perpl DelegatedAccount   │
 │ TradeRouter (band, leverage, market allowlist, slippage budget)  │
 │ Enforcer (permissionless freeze + bounty) · CircuitBreaker       │
 └──────┬───────────────────────────────────────────┬───────────────┘
        │ events                                    │ health reads
 ┌──────▼──────── OFFCHAIN (verifiable) ────────────▼───────────────┐
 │ Indexer (Envio HyperIndex/HyperSync, reorg-aware)                │
 │ Scoring engine (open code, deterministic, Merkle-committed)      │
 │ Keeper network (ours + anyone's) · Alerting · Risk analytics     │
 └──────────────────────────────────────────────────────────────────┘
```

## Contracts

| Contract | Role | Key rules | Reference design |
|---|---|---|---|
| `CreditPool` | AUSD deposits split into senior (paid first) and junior (first loss) shares | ERC-4626 with inflation-attack protection; withdrawal queue | 3Jane USD3/sUSD3 tranches; Maple v2 withdrawal manager; OpenZeppelin ERC-4626 |
| `CuratorVault` | A curator runs a pool with its own rules: minimum score, maximum line, markets, APR curve | Tighten instantly, loosen through a timelock; curator, allocator and guardian are separate roles | MetaMorpho roles and timelocks |
| `CreditLine` | One per borrower; creates and owns a Perpl DelegatedAccount with no operator | Only `TradeRouter` can trade; only `Settlement` can withdraw | Gearbox v3 credit accounts; Euler EVC controller pattern |
| `TradeRouter` | The only trade path | Price band around Perpl's onchain mark, leverage cap, market allowlist, per-line slippage budget | Gearbox adapter allowlist |
| `Enforcer` | `freeze(line)` callable by anyone when health is under 1.10, paid a bounty | Bounty paid from the line's margin, never the trader's protected share; a borrower cannot claim on their own line | Aave liquidation bonus; Mandate's open enforcement market |
| `Settlement` | Freeze, reduce-only close, `withdrawCollateral`, repayment waterfall | Principal, then interest, then trader; profit sweep only above debt plus buffer | |
| `HistoryLinkRegistry` | Links an existing Perpl account to a borrower by signature | One history backs at most one line, permanently | |
| `ScoreRoot` | Posts the Merkle root of every account's score per epoch | Challenge window before activation; maximum limit change per epoch | Solady `MerkleProofLib` |
| `CircuitBreaker` | Halts new borrowing if Perpl is paused, the mark is stale, AUSD depegs or an insurance fund is thin | Can only make things safer; never blocks repayment, freeze or withdrawal | |

### Invariants (fuzzed with a stateful handler, written so they can later become formal rules as in 3Jane's Certora specs)

1. Pool loss on any line is at most the principal lent to it.
2. No party other than `CreditLine` can move collateral out of its DelegatedAccount.
3. Pool assets equal idle plus lent plus accrued interest minus realized losses.
4. One linked history maps to at most one active line.
5. A line under the freeze threshold can always be frozen, including while new borrowing is paused.
6. No admin role can transfer user funds.

## Identity and authentication

| Layer | Design | Library |
|---|---|---|
| Sign-in | Passkeys through Mera; no seed phrase, extension or custody backend | `@category-labs/mera` |
| Onchain passkey checks | Opening a line, profit sweeps and recovery changes verify a WebAuthn signature onchain through Monad's P256 precompile at `0x0100` (EIP-7951) | Coinbase `base/webauthn-sol` (MIT); daimo `p256-verifier` test vectors |
| Session keys | Short-lived key scoped to `TradeRouter.trade` only, with expiry and notional cap; one-tap revoke | MetaMask `delegation-framework` caveat enforcers (Apache-2.0) |
| History ownership | EIP-712 signature from the existing Perpl account's wallet, with chain id, nonce and expiry | OpenZeppelin EIP712 |
| Devices and recovery | Several passkeys per account; adding one requires an existing one; guardian-plus-delay recovery; Mera encrypted export | |
| Backend session | Domain-bound passkey challenge, short-lived token; the backend holds no key that can move funds | |
| Admin and curator roles | Hardware wallet or multisig; pauser, parameter setter and upgrader are distinct | |
| Privacy | No email or name; history linking is opt-in; public pages show score bands unless the trader opts in | |

## Security

### Threat model

| Actor | Attack | Defense |
|---|---|---|
| Borrower | Drain margin by closing into a colluding bid | Mark-price band, slippage budget, no operator access |
| Borrower | Farm a record with self-trades | Score counts only PnL and fees against unrelated counterparties after wash-cluster netting (fill graph, funding source, 7702 delegate) |
| Borrower | Reuse one record for several lines | One-history-one-line registry |
| Borrower | Withdraw lent funds | Withdrawal is owner-only in Perpl's DelegatedAccount (proven in Phase 0) |
| Borrower | Stall a freeze | Permissionless enforcement with bounty |
| Manipulator | Move the mark to force or dodge freezes | Use Perpl's oracle-anchored mark; require breach across N blocks or a buffer before freezing |
| Curator | Reckless rules with depositors' money | Protocol-wide hard limits; timelocked loosening |
| Score signer | Post inflated scores | Merkle root, challenge window, per-epoch change cap, public recomputation |
| Admin key | Change rules or code | Multisig, timelock, immutable core (new versions deploy alongside), pause stops only new borrowing |
| Perpl dependency | Pause, unwind, or DelegatedAccount beacon upgrade by Perpl's admin | Circuit breaker, per-venue exposure cap, beacon-upgrade monitor, stated plainly |
| Stablecoin | AUSD depeg | Chainlink peg feed halts new borrowing |
| Frontend | Script injection, phishing | Strict CSP, SRI, no third-party scripts on signing pages, readable signing prompts |
| Infrastructure | Lying or failing RPC | Several providers cross-checked before keeper action |

### Assurance

Unit, fuzz and invariant tests; fork replays of the worst real Perpl days; scripted adversarial
simulations (wash rings, drain attempts, keeper outage); Slither and Aderyn in CI; gas and size budgets
in CI; written threat model, NatSpec, audit-ready spec, bug bounty policy and incident runbooks.

## Monad-specific engineering

Sources: docs.monad.xyz developer-essentials/differences, reserve-balance and reference/rpc-differences.

| Monad behavior | Handling |
|---|---|
| Senders pay for the gas limit, not gas used | Measured per-function gas budgets in tests; explicit tight limits per call |
| 10 MON reserve balance per EOA; EIP-7702 delegated EOAs cannot drop below it | Keeper, sponsor and bounty wallets hold a buffer with alerts; contracts never depend on sending MON; `dippedIntoReserve()` precompile at `0x1001` where relevant |
| Storage pages of 128 slots; one cold access warms the page | Pack each line's hot state into adjacent slots |
| 128 KB contract size limit | Plain modules, no proxy tricks needed |
| P256 precompile at `0x0100` | Onchain passkey verification |
| Block states Proposed, Voted, Finalized; several proposals per height possible | UI reads `latest`; accounting, scores and settlement read `finalized`; indexer tracks `blockId` and abandoned blocks |
| `eth_getLogs` limited to 100 blocks on public RPC | Envio HyperSync for history; RPC as cross-check |
| Full nodes do not serve arbitrary historical state | Indexer keeps its own snapshots |
| No global mempool | Less front-running; enforcement stays correct whoever wins the race |
| `eth_sendRawTransactionSync`, `monadNewHeads` | Fast receipts; keeper reacts per block |
| Foundry 1.8+ Monad EVM | Pinned toolchain; fork tests run with CLI `--fork-url` |

## Credit model

1. **Data:** every Perpl fill, open, close, liquidation and funding event; maker and taker pairs; first
   funding source per wallet; 7702 delegate links.
2. **Wash detection:** cluster wallets that mostly trade with each other or share funding or delegates;
   PnL inside a cluster nets to zero.
3. **Features:** PnL and fees against unrelated counterparties, days active, maximum drawdown,
   liquidations, typical versus maximum leverage, behavior after losses, concentration.
4. **Calibration:** score every account at past dates and measure liquidations and losses over the
   following weeks; publish accuracy, calibration curves and stability across periods.
5. **Limit:** a multiple of the trader's own first-loss deposit, capped by external fees paid and by
   curator rules; grows after clean cycles.
6. **Pricing:** base rate plus risk premium by score band plus utilization curve.
7. **Governance:** versioned models; per epoch compute, commit root, challenge window, activate.
8. **Explainability:** top factors behind each limit and what would raise it.

## Capital and risk management

Caps per borrower, market, correlated cluster and venue. Reserve fund from a share of interest ahead
of junior losses. Live stress results ("BTC minus 20 percent in one block costs the pool X"). Perpl
insurance-fund headroom monitor that tightens limits as auto-deleveraging gets closer. Health bands:
1.15 warn and allow top-up, 1.10 freeze, Perpl maintenance margin below both.

## Keeper and enforcement network

Our keeper checks every line each block and simulates before sending. An open-source keeper lets anyone
enforce and earn the bounty in the same transaction. Liveness alerts fire when a line stays below
threshold for N blocks. RPC failover; gas wallets watched against the reserve rule.

## Data platform

Envio HyperIndex for live events and HyperSync for backfill, reorg-aware. Indexed totals reconcile
against Perpl's public statistics and onchain account state, with alerts on mismatch. The scored dataset
and backtest are published for reproduction.

## Product

| User | Screens |
|---|---|
| Trader | Passkey onboarding; eligibility check by address; history linking; limit explainer; trade ticket showing the freeze price before submission; health meter with top-up; profit sweep; session-key management |
| Lender | Senior or junior choice with live yield and risk; loss waterfall; backtest evidence; withdrawal-queue estimate |
| Curator | Rule editor; live risk report (exposure, distance-to-freeze histogram, stress); export |
| Public | Explorer of lines (anonymized by default), enforcement history with bounties, epoch roots, "verify this number" on every figure |

Accessible, mobile-first, plain language in the main flow.

## Observability and operations

Metrics for utilization, lines by health band, freezes, bounties, keeper latency, indexer lag and RPC
disagreement. Alerts for keeper down, stuck unhealthy line, indexer lag, reserve-balance proximity,
Perpl beacon upgrade and AUSD peg. Public status page and a runbook per alert.

## Governance and compliance

Immutable core contracts with side-by-side versioning; multisig and timelock for parameters; pause that
only stops new borrowing; geofencing consistent with Perpl's own restrictions (development runs on
testnet and mainnet forks); optional KYC pools for institutional curators; plain-language terms.

## Open-source references

| Repo | Used for | License and use |
|---|---|---|
| Gearbox core-v3 | Credit account and adapter allowlist design | Ideas only |
| 3Jane moneymarket-contracts | Senior/junior tranches, credit lines, Certora specs | Ideas only |
| Morpho MetaMorpho | Curator vault roles and timelocks | GPL-2.0, ideas only |
| Euler EVC and vault kit | Controller enforcement over borrower accounts | Ideas only |
| Maple core-v2 | Withdrawal queue and loan accounting | Ideas only |
| OpenZeppelin contracts | ERC-4626, access control, timelock, EIP-712 | MIT, dependency |
| Solady | Merkle proofs, gas-efficient math | MIT, dependency |
| base/webauthn-sol | WebAuthn verification with P256 precompile | MIT, dependency |
| daimo p256-verifier | P256 test vectors | MIT, test data |
| MetaMask delegation-framework | Caveat enforcers for session keys | Apache-2.0, dependency |
| PerplFoundation/delegated-account, dex-sdk | Custody primitive, Exchange ABI, order types | Deployed contracts and ABIs |

Competitor repositories (Mandate, xorr, Lifeline) are read for facts and ideas only; no code is copied.

## Phase 5: verifiable scores

Each epoch, the publisher runs the fixed rule in `data/backtest.py` over all Perpl history strictly
before the cutoff block. It writes one Merkle leaf per scored Perpl account:
`(epoch, perplAccount, features, limit, aprBps)`. `features` contains active days, completed
closes, realized PnL after wash-cluster discount, deposit-weighted average leverage, liquidation
history, and wash share. Leaves use OpenZeppelin's standard double-hash Merkle encoding over `(chainId, oracle address, epoch, perplAccount, features, limit, aprBps)`, so a proof for one market's oracle, or one chain, never verifies on another. `ScoreOracle.leafHash` is the single definition.

The approval rule is exactly the Python rule: an account is eligible when `active_days >= 3`,
`n_closes >= 10`, `liq_hist == 0`, `pnl_ext > 0`, `avg_lev <= 5.0`, and `wash_pair == false`.
For an eligible account the credit limit is `floor(min(max_deposit * 2, 10,000))` AUSD, with AUSD
represented in whole dollars for the published limit; an ineligible account has limit zero. The
published APR is 800 bps, the fixed local approval rate. The onchain `ScoreRules` implementation
uses integer feature units and the same comparisons and limit cap.

`ScoreOracle` accepts a proposed `(epoch, root, cutoffBlock, dataURI)` only from the market's
publisher, with at least the minimum bond; epoch numbers only increase. A one-day challenge window is timelocked by the market curator like other loosening changes.
After the window, an unchallenged proposal can be finalized. A trustless challenger can submit a
leaf and proof when its stated limit or APR does not follow from the features; the contract checks
the rule and rejects the root immediately, paying the publisher's bond to the challenger. An
arbitrated challenger can report features that disagree with chain data by posting a bond. The
market guardian (read live from the market's `RiskCurator`) resolves that case at once, with no
timelock; an open case prevents finalization. Bonds are paid by pull (`claim`), so no recipient can
block a payout, and disputes left open on a rejected root reclaim their bonds.

The trust boundary is explicit. Merkle inclusion, epoch freshness, the feature-to-limit formula,
and trustless consistency challenges are enforced by contracts. The publisher's historical data and
an arbitrated feature dispute remain offchain claims until the guardian reviews the evidence. A
borrower can open a scored line only after a finalized root, a matching history link, a current epoch,
and a principal no larger than the leaf limit have all been checked onchain.

Wash detection works on clusters, not just pairs. Two accounts are linked when each is at least 20%
of the other's traded volume; linked accounts form clusters; an account trading half or more of its
volume inside its own cluster is a wash trader, and its PnL is discounted by that inside share. The
"each side" condition is what keeps honest order-book traders out: a market maker's volume is spread
over many clients, so a client trading almost only against it is still a tiny share of the maker's
volume and never links.

Wash evidence (`scorer/test_wash_ring.py`, run through the real `backtest.features` and
`score_margin_line`): a reciprocal pair, a 3-account ring and a 5-account ring all score zero
(flagged, PnL discounted to 0, denied); a ring that also trades 9% of its volume with a stranger keeps
only that 9% of its profit; ten clients trading 100% against one market maker stay approved with full
PnL. The earlier rule (reciprocal top counterparties only) approved one member of a 3-account ring with
its full profit; that case is now a test. On the real history the cluster rule changes no approval:
the 7- and 14-day results are identical to the pair rule's.

Limit: a wash network that spreads each account's volume across more than five partners (each under
20%) is not linked. Funding-source clustering (accounts first funded from the same wallet) is the
planned complement and is not built.

## Phase 1 results: the score predicts liquidation

Walk-forward backtest on all of Perpl's mainnet history, blocks 54,972,991 to 112,140,000 (Feb 12 to
Oct 9, 2026; about 70 million decoded events, 3,643 liquidations). `data/decode.py` turns raw chunks
into per-event tables; `data/backtest.py` scores every trader at weekly checkpoints, from two weeks
after Perpl launched until the outcome window runs out, using only events before the checkpoint, then
checks who was liquidated in the following 7 or 14 days among traders who kept trading. The approval
rule was fixed before looking at outcomes:

- at least 3 active days and 10 closed trades;
- no liquidation so far;
- positive realized PnL after discounting PnL made inside a wash cluster;
- deposit-weighted average leverage of 5x or less;
- not a wash trader (half or more of its volume inside a cluster of accounts that are each 20% or more
  of one another's volume; see Phase 5).

The continuous score ranks return on capital, win rate, leverage (lower is better), drawdown and
active days, with a heavy penalty for any past liquidation.

| 7-day horizon, 15,173 trader-checkpoints over 32 weeks | Liquidated |
|---|---|
| All active traders | 12.3% |
| Approved by Margin Line (560, 179 distinct traders) | **3.8%** (95% CI 2.5% to 5.7%) |
| Denied | 12.7% |
| Experienced only (3+ days, 10+ closes) | 12.9% |
| Experienced but denied by Margin Line | 13.3% |

| Ranking power (AUC, 0.5 = chance) | 7 days | 14 days |
|---|---|---|
| Margin Line score | **0.66** | **0.66** |
| Volume (naive lender) | 0.52 | 0.52 |
| Raw realized PnL | 0.44 | 0.44 |
| Random | 0.50 | 0.49 |

- Approved traders were liquidated less often than the average trader in 26 of 32 weekly checkpoints
  (7 days) and 25 of 31 (14 days).
- At 14 days: approved 6.7% against 19.0% denied.
- The edge is not just experience: approvals against experienced traders it denied, one-sided Fisher
  exact p = 4e-14 (7 days) and 1e-18 (14 days).
- The edge is weaker in Perpl's first months: February to May, 8.3% of approvals liquidated against
  14.4% denied (72 approvals); June to October, 3.1% against 12.4% (488 approvals). A young market
  with few experienced traders gives the rule less to work with.
- Raw profit ranks worse than random: the biggest recent winners are disproportionately the ones who
  blow up, which is why the score uses risk-adjusted return and leverage rather than profit.

**How these numbers changed.** The first reported run covered blocks 95M to 107M (six weekly
checkpoints): 3.5% approved against 15.7% denied. Running on all history surfaced two pipeline bugs,
both fixed: (1) the block-to-time table started at block 95M, so every earlier event was stamped
Aug 11 and veterans' active days collapsed to one; it now has real timestamps from Perpl's first block;
(2) the backtest read only Perpl's V2 position events, introduced at block 78,474,495 (early June), so
positions opened before June had no leverage or deposit and passed the leverage rule by default; V1
events are now read too. With both bugs present, February to May showed no edge at all (12.7% of
approvals liquidated against 11.6%); the fix removed 252 early approvals that were high-leverage traders.

**Limits.** Traders recur across weekly checkpoints, so the p-values overstate independence; the
effect is large and consistent across weeks, so the conclusion stands. Funding-source clustering
(shared first AUSD inflow) is not implemented.

**Reproduce.** `data/refresh.sh` downloads any newly published ranges, decodes them (streaming to
disk, so full history fits in memory), and reruns both horizons. Reports:
`docs/evidence/backtest-h7.json` and `docs/evidence/backtest-h14.json`.

## Phase 2 implementation notes

Contracts: `src/CreditPool.sol`, `src/CreditManager.sol`, `src/CreditLine.sol`, `src/TradeGuard.sol`.
Tranches, curator vaults and the withdrawal queue are Phase 6; the pool here is single-tranche with
withdrawals limited to idle liquidity.

**Valuation, checked against real Perpl.** `test/fork/PerplValuation.t.sol` opens and closes a real
BTC position on a testnet fork. Equity computed as free balance + position margin + unrealized PnL +
funding predicted 499.88 AUSD before the close; the realized balance after it was 499.77, the gap
being the close fee and spread. CreditLine uses exactly this, flooring each position at zero because
Perpl margin is isolated (a position cannot lose more than its own margin).

**Behaviors pinned by tests.**

| Behavior | Where |
|---|---|
| Line owns its Perpl account, borrower is never an operator, cannot withdraw or trade around it | `test/unit/CreditLine.t.sol` |
| First-loss deposit, limit, expiry, single-use approval, one open line per borrower | `test/unit/CreditLine.t.sol` |
| Band, leverage, IOC-only, no collateral moves, order types, market allowlist, stale mark | `test/unit/CreditLine.t.sol` |
| Cannot add risk when health is low; sweep only above sweep health; top-up and repay | `test/unit/CreditLine.t.sol` |
| Freeze only when unhealthy, stranger unwinds and settles, gap through bankruptcy loses at most principal | `test/unit/CreditLine.t.sol` |
| Withdrawals capped at idle, only lines settle, no over-settlement, inflation attack unprofitable | `test/unit/CreditPool.t.sol` |
| The six invariants under random lender, borrower, keeper, market and venue actions | `test/invariant/` |
| Full lifecycle and freeze-and-unwind against real Perpl on testnet and mainnet forks | `test/fork/CreditLineFork.t.sol` |

**Invariant campaign.** 10,000 runs of 128 random actions each (1,280,000 calls) with
fail-on-revert on, all six invariants held. Coverage counters across the campaign: 59,756 lines
opened, 26,715 trades, 43,280 sweeps, 732 freezes, 725 unwinds, 43,342 settlements, and 595
settlements where the pool took a loss, each within that line's principal. Reproduce with
`FOUNDRY_INVARIANT_RUNS=10000 FOUNDRY_INVARIANT_DEPTH=128 FOUNDRY_INVARIANT_FAIL_ON_REVERT=true forge test --match-path "test/invariant/*"`.

**Gas and size (Monad bills the gas limit).** Unit-test measurements against the mock exchange:
`openLine` about 0.94M (EIP-1167 clone), `trade` up to about 0.17M plus Perpl's own cost (about
0.5M on the real book), `freeze` about 0.07M, `unwind` about 0.09M, `close` about 0.26M. Runtime sizes:
CreditLine 14.3 KB, CreditManager 7.0 KB, CreditPool 8.3 KB, TradeGuard 5.3 KB (limit 128 KB).

**Known gaps carried to later phases.** Underwriter role instead of score epochs (Phase 5); a frozen
line always closes, it cannot be unfrozen; Perpl withdrawal rate limits can delay settlement for very
large lines; single tranche and no withdrawal queue (Phase 6).

## Phase 3 implementation notes: identity

Contracts: `src/IdentityRegistry.sol`, `src/HistoryLinkRegistry.sol`; session keys and passkey-gated
actions in `src/CreditLine.sol`; passkey requirement in `src/CreditManager.sol`.

- **Passkeys as a fresh second factor.** Mera derives the user's wallet from a passkey, but keeps the
  derived key in page memory for the session. Sweeping profit, closing a line and granting a session
  key therefore also require a WebAuthn assertion at that moment, verified onchain with OpenZeppelin
  WebAuthn (v5.7.0) over Monad's P-256 precompile at `0x100`. Each approval is bound to chain, registry,
  consuming contract, user nonce and a hash of the exact arguments, so it cannot be replayed, used on
  another line, inflated (a $10 sweep approval cannot authorize $400) or burned by a front-runner. The
  registry also checks rpIdHash, which OpenZeppelin deliberately leaves out.
- **Devices and recovery.** Up to eight passkeys per user; adding or removing one needs an existing one;
  the last cannot be removed; a guardian can propose a replacement that takes effect after three days,
  which the user can cancel with any current passkey. Recovery retires all old keys by moving to a new
  key epoch.
- **Session keys.** Trade only, per-order and total notional caps (priced with Perpl's own decimals),
  at most seven days, revocable by the borrower or the key. They can never sweep, close, repay from the
  account or grant keys, and they earn no freeze bounty.
- **History linking.** The wallet that controls a Perpl account (directly, or as owner of a Perpl
  DelegatedAccount) signs an EIP-712 link naming the borrower. One account links to one borrower,
  permanently. Accounts owned by Margin Line lines cannot be linked: their owner is a contract.

Evidence:

| Check | Where | Result |
|---|---|---|
| Registry attacks: forged key, replay, front-runner, wrong action, phishing domain, no user verification, malicious recovery | `test/unit/IdentityRegistry.t.sol` | 14 pass |
| Session caps, expiry, revocation; session key cannot sweep, close, repay from account or grant | `test/unit/Sessions.t.sol` | 10 pass |
| History links: own wallet, DelegatedAccount owner, someone else's account, reuse, replayed signature, expiry, line-owned account | `test/unit/HistoryLinkRegistry.t.sol` | 7 pass |
| Monad P-256 precompile present; real Perpl testnet account linked | `test/fork/IdentityFork.t.sol` | precompile 7,475 gas; full approval about 110k gas on Monad versus about 302k without the precompile |
| Invariant campaign including a malicious session-key actor | `test/invariant/` | 3,000 runs x 128 calls, all invariants held, 0 successful extractions |
| Passkey-only onboarding through a real browser WebAuthn stack on live Monad testnet | `e2e/src/run.ts`, `e2e/evidence/passkey-onboarding.json` | passed (below) |

Live run (headless Chromium, virtual platform authenticator with user verification and PRF, Mera
creating the passkey and deriving the wallet, rpId `localhost`):

| Step | Transaction |
|---|---|
| Register passkey | `0x63831177412265877150a605d59276f17561b68b28bdd2ac799c5b485ea52f8d` |
| Open line (100 AUSD deposit, 100 borrowed) | `0xaf8cde7af3b346a9b9f7159286e33719d4e11b979343da4ef60489661982affa` |
| Same assertion for a 10x sweep | refused in simulation with `InvalidAssertion` |
| Sweep 20 AUSD with a browser assertion | `0x6f5ae93d857af0572a9af93ce634ed0573d3a11bfcde3b8b44b56ed2c1ba5cdd` |
| Close with a browser assertion | `0x16b823b82be8efb2eaecda8851f14a01a0f70f72dce50f54616da6e951c296c0` |

## Phase 4 implementation notes: enforcement

Contracts: `src/CircuitBreaker.sol`; freeze bounty in `src/CreditLine.sol` and `src/CreditManager.sol`.
Keeper: `keeper/src/keeper.ts`.

- **Freeze bounty.** Whoever freezes an unhealthy line is paid at settlement, first in the waterfall:
  0.5% of debt, capped at 250 AUSD by default (governance ceiling 2%). The borrower and its session keys
  never earn it.
- **Circuit breaker.** Blocks only new risk (opening lines, opening or growing positions, sweeps) on:
  manual pause (owner or pauser; only the owner resumes), Perpl market paused (status 0), AUSD below a
  floor or its Chainlink feed stale (optional: mainnet has AUSD/USD feeds, testnet has none), or a
  Perpl insurance fund below a share of open-interest notional. It never blocks repaying, closing
  positions, freezing, unwinding or settling.
- **Keeper.** Independent process, permissionless actions only. One batched read per tick (Multicall3:
  block number, freeze threshold, every line's state and health), then one send for the freeze: nonce
  and fees cached, transaction signed locally with a fixed measured gas ceiling, sent with
  `eth_sendRawTransactionSync`. Monad bills the gas limit, and receipts report the limit as gas used.

Evidence:

| Check | Where | Result |
|---|---|---|
| Bounty paid to freezer, cap, none for borrower or session keys, governance ceiling | `test/unit/Enforcement.t.sol` | pass |
| Pause blocks new lines, new positions, sweeps; pause never blocks closing, repaying, freezing, unwinding, settling | `test/unit/Enforcement.t.sol` | pass |
| Venue pause, thin insurance, depeg and stale feed triggers | `test/unit/Enforcement.t.sol` | pass |
| Invariants with random pausing and venue pauses, bounty within cap | `test/invariant/` | 3,000 runs x 128 calls, all held |
| Full protocol on real Perpl forks with the insurance breaker enabled | `test/fork/CreditLineFork.t.sol` | pass on testnet and mainnet forks |
| Independent keeper freezes, unwinds and settles a live line | `e2e/src/keeper-liveness.ts` | see below |

Live keeper runs on Monad testnet (the owner raises the freeze threshold above the line's health in
block B; the keeper learns of it only from chain data):

| Run | Unhealthy in block | Keeper detected in block | Frozen in block | Lag | Evidence |
|---|---|---|---|---|---|
| First keeper (simulate, estimate, send, poll) | 69,904,465 | 69,904,465 | 69,904,469 | 4 blocks, 1.5 s | `e2e/evidence/keeper-liveness.json` |
| Fast path (batched read, cached nonce and fees, sync send) | 69,905,489 | 69,905,489 | 69,905,491 | 2 blocks, 0.52 s | `e2e/evidence/keeper-liveness-fast.json` |
| Pushed blocks (WebSocket newHeads, current deployment) | 70,250,222 | 70,250,222 | 70,250,224 | 2 blocks, 0.45 s | `e2e/evidence/keeper-liveness-ws.json` |

Both runs unwound the real Perpl position, settled the line, paid the keeper its bounty and left the
pool with zero loss. **The exit target of one block was not met: the best measured lag is two blocks.**
A transaction sent after seeing block B can land at the earliest in B+1, and only if it reaches the next
leader before that block is sealed. From the test machine the RPC round trip was about 0.29 s against
blocks of roughly 0.3 to 0.4 s, so B+2 is the floor there; a keeper colocated with a Monad RPC node is
expected to reach B+1. That is unverified until measured.

**Where the second block goes (measured Oct 11).** Monad itself allows a one-block reaction from a
laptop: over a WebSocket, Monad pushes each block the moment it is proposed (round trip 74 ms against
about 290 ms over HTTP), and a pre-signed transaction sent the instant a block arrives landed in the
next block 14 times out of 20 and in the one after 6 times (zero-value transfers, 0.044 MON). The keeper
now runs on that push feed instead of polling, but it must still read the line's health before it can
send a freeze (a freeze on a healthy line reverts, and Monad bills the full gas limit), and that one
extra round trip was enough to miss the next block in the live run above. Reaching B+1 reliably needs
the freeze decision without a read: for example, deciding locally from the pushed block's logs (mark
and risk-parameter updates) against each line's precomputed freeze price. Not built.

That run tightened the live market's freeze threshold to 135% (open and sweep 136%) through the
curator; the restore to 110/130/125% is queued in the timelock and executable from Oct 12, 2026
17:07 PDT (`restore_pending.execute` in the evidence file).

## Phase 6 implementation notes: capital and curation

Contracts: `src/CreditPool.sol`, `src/TrancheVault.sol`, `src/RiskCurator.sol`, `src/MarketFactory.sol`,
`src/RiskLens.sol`; caps in `src/CreditManager.sol`, `src/TradeGuard.sol` and `src/CreditLine.sol`.

- **Two tranches and a reserve.** Lenders hold ERC-4626 shares of a senior or a junior tranche
  (`TrancheVault`, one per tranche, virtual-share offset against inflation attacks); the pool keeps
  the books and the cash. Every interest payment goes 10% to a reserve, then to the senior's unpaid
  target (8% a year, accrued only on the senior's share of principal actually lent, so idle cash
  builds no claim), then the rest to junior. Losses go reserve, then junior, then senior. Junior must
  stay at least 20% of lender capital: senior deposits beyond that and junior withdrawals below it are
  refused. Accounting identity, checked as an invariant: senior + junior + reserve = cash + principal
  lent.
- **Withdrawal queue.** Instant withdrawals take only idle cash not held as reserve. Beyond that a
  lender queues shares (escrowed, still earning or losing with the tranche) and anyone can pay the
  queue in order as loans repay. Liquidity owed to the queue is not available to instant withdrawals,
  so nobody can jump the line.
- **Caps.** Utilization at most 90% (checked exactly: a floored basis-point figure let 90.0001% through
  a 90% cap, caught by a test). One line may borrow at most 25% of lender capital. A per-market
  exposure cap bounds one line's position notional at the mark, checked after every risk-increasing
  trade; reducing a position is never blocked.
- **Curator markets.** `MarketFactory` deploys a complete isolated market (pool, both vaults, guard,
  manager, line implementation, breaker, curator) and hands every component to a `RiskCurator` in one
  transaction (16.1M gas). Since the factory wrote every component, `isMarket(pool)` is proof of real,
  correctly wired code, which a registry of self-reported addresses could not give. The factory carries
  about 75 KB of creation code, which only fits because Monad allows 128 KB contracts.
- **Tighten now, loosen later.** The curator can make its market safer instantly (lower caps, lower
  leverage, narrower bands, stricter health thresholds, a higher junior floor or reserve share, a higher
  insurance floor, removing the underwriter, pausing). Everything else, including unpausing, the senior
  rate, installing an underwriter, ownership changes, the guardian and shortening the timelock, is
  queued publicly for 1 to 30 days; anyone executes it when it matures and the guardian can veto it.
  Lenders who disagree have the whole timelock to leave. Pattern after MetaMorpho.
- **RiskLens.** A read-only stress view: shock any market's price, revalue every open line's Perpl
  positions (isolated margin, floored at zero), settle each line the way CreditLine does (bounty,
  interest, principal) and run the unrecovered principal through the loss order. Output: loss per line
  and what the reserve, junior and senior would each pay.

Evidence:

| Check | Where | Result |
|---|---|---|
| Interest and loss waterfalls, senior shortfall carried forward, no senior accrual on idle cash | `test/unit/CreditPool.t.sol` | match hand calculations |
| Loss order for any tranche sizes, reserve and loss | `testFuzz_lossWaterfallOrder` | 1,000 runs, held |
| Subordination floor, queue order, queue priority over instant withdrawals, inflation attack | `test/unit/CreditPool.t.sol` | pass |
| Concentration and exposure caps | `test/unit/Caps.t.sol` | pass |
| Factory wiring, isolation between markets, instant tightening, timelocked loosening, guardian veto | `test/unit/Curator.t.sol` | pass |
| RiskLens equals a hand calculation (two lines, BTC -40%: junior pays 1,013.4012) and reaches senior when junior is thin | `test/unit/RiskLens.t.sol` | exact |
| RiskLens prediction equals the loss actually realized after a real crash, freeze, unwind and settle | `test/unit/RiskLens.t.sol` | exact |
| Protocol invariants with tranche deposits, queued and instant withdrawals: tranche identity, vaults hold no cash, senior never loses while junior or the reserve has funds | `test/invariant/` | 3,000 runs x 128 calls (384,000), all 11 held; 4,870 queued and 2,023 paid withdrawals, 8,857 senior deposits, 40 losses |
| Full protocol on real Perpl forks with tranche vaults | `test/fork/CreditLineFork.t.sol` | pass on testnet and mainnet forks |

Limits, stated plainly: in the stateful campaign no loss was ever large enough to reach senior (pool
losses are rare there, since the borrower's deposit absorbs most crashes), so the senior-protection
invariant is backed by the fuzzed waterfall test and the hand-calculated tests, not by the campaign.
The live testnet deployment below predates Phase 6; redeploying through the factory costs about 28.1M
gas, and the deployer needs a faucet top-up first.

## Live testnet deployment

`deployments/monad-testnet.json`: the full system through `MarketFactory`, deployed from block
69,981,100 by `script/Deploy.s.sol` (rpId `localhost` for the end-to-end tests). One BTC market,
seeded with $7,000 senior and $3,000 junior. Score epoch 2 (all 5,257 scored Perpl mainnet
accounts, 108 approved, root `0x7de0c84c...5881d196`) was posted with a 0.1 MON bond, went unchallenged
through its one-day window, and was finalized on Oct 11, 2026 (tx `0x67b85d70f0a8c5c9b54b8a22f20c5726ff0db89eb98f4e400ce5057ce5166b77`, block
70,306,994; `latestFinalizedEpoch` = 2); the publisher then claimed the bond back (tx
`0x3b2296152ea2635945d744d6fbec416e7d4aa8c62f1b05f5710703339f7e9136`). `scorer/verify_onchain.py` against testnet: root matches, finalized, seven
real leaves verify, a tampered limit fails.

**Scores cannot open lines on testnet.** Every leaf scores a Perpl account on Monad **mainnet**, where
the trading history is. `openLineWithScore` requires that account to be linked to the borrower in
`HistoryLinkRegistry`, and the registry checks ownership against the Perpl exchange on the chain it
runs on, so a mainnet account cannot be linked on testnet. On testnet, lines therefore open through
the underwriter path, labeled in the app as a demo approval, never as a score. The scored path itself is
covered by unit tests (`test/unit/ScoreManager.t.sol`) and the invariant handler, which opens scored
lines from finalized epochs with linked accounts. Epoch 1 was built before the full-history fixes; it was retired live
through the dispute path: a bonded arbitrated challenge, the guardian ruling it invalid, and the
challenger claiming both bonds. The earlier Phase 0 to 4 deployment is in git history.

| Contract | Address |
|---|---|
| IdentityRegistry | `0xc1b2aC9321335789F4bdC28B2f423E474d672FaD` |
| MarketFactory | `0xD94860A4587c5e8CD3D601d61577c33C297a335c` |
| RiskLens | `0x77C6cAC3FA8476e00b15d15a659E8Afc1C315C06` |
| HistoryLinkRegistry | `0xa2621f741E66139DD579FB250ed9441624791E89` |
| CreditPool | `0x8Ec3a1683F1a74800AC0c9a242455a98b75E2A54` |
| Senior vault | `0xadBD73750d49201b8c42Dc9FDc8dec7Be7716Bc6` |
| Junior vault | `0x5e430A7b1924f0eb0FF129f5Bc6b7AD0256DB727` |
| CreditManager | `0x8B300a2336e359b8490A46BE5742Ee49996BD95f` |
| TradeGuard | `0x7a2635b16D51F2F2bA2045aA3723f039C6ed1BC9` |
| CircuitBreaker | `0xC61d993336C4c94feEF3f70B186609596f6d3cE9` |
| RiskCurator | `0x7E3808E8124C3E42546F3e2f16f7f8c944208A47` |
| CreditLine implementation | `0x0165dE2063fe2277C144fc6e2c26648833802BF2` |
| ScoreOracle | `0xE3520b1344b9E088AbD2313b17d17df00469e463` |

Live evidence: `e2e/evidence/newcomer-testnet/` (`LIVE=1` run of `e2e/src/newcomer.ts`). Through the
app, a new passkey account opened a line, granted and revoked a session key, opened and closed a BTC
long on Perpl's real book, swept 248.73 AUSD with a passkey approval, closed the line (pool repaid,
zero loss) and lent to junior. Two steps happen outside the UI on testnet because their buttons are
fork-only: the deployer sends the new wallet 0.8 MON and 2,000 test AUSD, and approves it for $1,500
as underwriter (the score epoch is still in its challenge window, and a mainnet score cannot be
linked on testnet).

Cost on Monad, for planning: the full deploy cost 5.08 MON at 102 gwei (MarketFactory 2.38 MON,
`createMarket` 2.20 MON), more than the simulation suggested, because Monad bills the gas limit.
Seeding cost 0.055 MON and posting the epoch 0.12 MON including the bond.

Notes from going live on Monad: a wallet funded in the last block cannot send yet (the reserve-balance
check reads a balance a few blocks old), so scripts wait four blocks after funding; and a reverted
transaction still pays its full gas limit, so book-dependent Perpl trades get a deliberate gas ceiling
instead of a tight estimate.

## Build sequence

Each phase has a pass or fail exit test. Order is by risk: real-data and key-boundary risks first.

| # | Phase | Exit test |
|---|---|---|
| 0 | Prove the hard parts: contract-owned Perpl account trades and blocks withdrawal; full mainnet history indexed | Fork tests pass on testnet and mainnet (done); live testnet transaction hashes (done); indexed totals reconcile with Perpl's public numbers (done, against Perpl's own mainnet contract state at block 112,140,000, since its API is geo-blocked from the US: 5,444 accounts created = `numberOfAccounts()`, and long and short open interest rebuilt from every position event equals Perpl's figure exactly in all 11 markets, 692 open positions; `data/reconcile.py`, `docs/evidence/reconcile.json`) |
| 1 | Does the score work: backtest on real history | Reproducible report showing the score separates safe from risky traders (done, all of Perpl history Feb to Oct: 3.8% vs 12.7% liquidated within 7 days, AUC 0.66, p 4e-14) |
| 2 | Core contracts: pool, line, router, settlement | Six invariants hold across at least 10,000 fuzz runs (done); fork replay of the worst real day loses no more than principal (done: Aug 19, 2026, the day with the most Perpl liquidations (249) and the largest BTC move (+7.4%, 9% low to high), replayed minute by minute on a fork against six lines sized from epoch 2's approved traders, half long, half short. Approved terms: no line froze and the pool lost nothing, even with shorts entering at the day's low (lowest health 110.2%, freeze at 110%). Market-maximum credit with the keeper running: one line froze, unwound and settled, pool loss 0. Same with the keeper offline until the close: the pool lost $62.45 of that line's $1,580.54 principal, taken from the reserve, then junior, senior untouched. Pool accounting identity held every minute; unwinds filled at the guard's worst allowed price. `e2e/src/worst-day.ts`, `data/worst_day.py`, evidence in `e2e/evidence/worst-day/`) |
| 3 | Identity: passkeys, P256, session keys, history linking, recovery | Passkey-only onboarding end to end (done, live testnet); a scoped session key cannot sweep (done) |
| 4 | Enforcement: permissionless freeze, bounty, keeper, circuit breakers | An independent bot freezes a line within one block on testnet (built and live; best measured lag 2 blocks, 0.45 s with the keeper on Monad's pushed block feed; one block not yet met, though the network allows it: a transaction sent the instant a block is pushed lands in the next block 70% of the time, and the keeper's health read before freezing costs the rest) |
| 5 | Score pipeline: wash netting, epoch roots, challenge window, explainer | Done: pairs and 3- and 5-account wash rings score zero while market-maker clients stay approved (`scorer/test_wash_ring.py`); a real epoch's proofs verify onchain on the fork (`scorer/verify_onchain.py`); `test/unit/ScoreOracle.t.sol` rejects an inconsistent leaf and exercises arbitration; `scorer/epoch.py` reproduces a 2,123-leaf root and proof |
| 6 | Risk layer: tranches, caps, curator vaults, stress, insurance-fund monitor | Stress output matches a hand calculation (done: exact, and equals the realized loss after a real crash); curator rules enforced (done: instant tighten, timelocked loosen, guardian veto) |
| 7 | Apps: trader, lender, curator, explorer, verification | Done: a newcomer completes borrow, trade and sweep unaided, through the UI only, twice in a row from a fresh fork (`e2e/src/newcomer.ts`); lender queue, curator rules, stress and explorer figures equal direct contract reads (`e2e/src/roles.ts`); see docs/APP.md |
| 8 | Hardening: static analysis clean, threat model, runbooks, monitoring, CI budgets | Done: Slither and Aderyn findings fixed or explained (one real fix: no profit sweep against a stale or invalid Perpl price), threat model and runbooks in docs/SECURITY.md and docs/RUNBOOKS.md, CI workflow with gas and size budgets, every monitor alert fired by a deliberate failure on the fork (`monitor/drills/drills.ts`) |

## Phase 7 underwriter limit

The underwriter imports the fixed approval rule and score from `data/backtest.py`. For an approved
borrower, the credit limit is `min(2 * max historical deposit, 10,000 AUSD)`, rounded down to whole
AUSD. A denied borrower receives a zero limit. A local-only demo approval uses the same limit cap when
history is absent, and is labeled as simulated in every service response and UI.
