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

## Build sequence

Each phase has a pass or fail exit test. Order is by risk: real-data and key-boundary risks first.

| # | Phase | Exit test |
|---|---|---|
| 0 | Prove the hard parts: contract-owned Perpl account trades and blocks withdrawal; full mainnet history indexed | Fork tests pass on testnet and mainnet (done); live testnet transaction hashes (done); indexed totals reconcile with Perpl's public numbers (needs HyperSync token) |
| 1 | Does the score work: backtest on real history | Reproducible report showing the score separates safe from risky traders, or a redesign |
| 2 | Core contracts: pool, line, router, settlement | Six invariants hold across at least 10,000 fuzz runs; fork replay of the worst real day loses no more than principal |
| 3 | Identity: passkeys, P256, session keys, history linking, recovery | Passkey-only onboarding end to end; a scoped session key cannot sweep |
| 4 | Enforcement: permissionless freeze, bounty, keeper, circuit breakers | An independent bot freezes a line within one block on testnet |
| 5 | Score pipeline: wash netting, epoch roots, challenge window, explainer | A scripted wash ring scores zero; a challenged bad root is rejected |
| 6 | Risk layer: tranches, caps, curator vaults, stress, insurance-fund monitor | Stress output matches a hand calculation; curator rules enforced |
| 7 | Apps: trader, lender, curator, explorer, verification | A newcomer completes borrow, trade and sweep unaided |
| 8 | Hardening: static analysis clean, threat model, runbooks, monitoring, CI budgets | Every alert exercised by a deliberate failure |
