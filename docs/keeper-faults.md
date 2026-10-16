# Local keeper and execution faults

`test/unit/KeeperFaults.t.sol` schedules the existing protocol contracts and
`MockPerplExchange` in Foundry's isolated EVM. The fixture uses the actual
`CreditLine`, `TradeGuard`, pool, vaults, identity registry, delegated account,
and account factory. Each scenario starts from a new fixture.

## Run the controls

With the repository's pinned Foundry dependencies available:

```sh
forge test --offline --match-contract 'KeeperFaultsTest|GuardRoundingTest' -vv
python -m pytest -q scorer/test_market_path.py
```

The default configured-path test uses four synthetic marks. A retained path can
be supplied in `H3_STRESS_PROTOCOL_JSON`, a JSON object with `label`,
`prices_pns`, `keeper_every_minutes`, and `exit_spread_bps`. The first mark must
be 1,000,000; at most 1,441 marks are accepted. Exit spread is bounded to 50 bp
in this path runner. Entries retain the fixture's 5 bp spread.

A full instrumented day requires a larger local test gas budget:

```sh
forge test --offline --gas-limit 4000000000 --match-test test_configuredMarketPath -vv
```

This budget covers an entire instrumented scenario in one test invocation.
Its gas total includes test scheduling and trace serialization. Gas for that
invocation is not an estimate for an individual keeper transaction.

## Required controls

| Fault | Trigger and oracle |
| --- | --- |
| Keeper delay | A small long line first breaches health at minute 1 on a 100%, 85%, 60%, 60% path. Freeze and exit at minute 1 loses no principal; delaying until minute 3 loses 1,013.402347 AUSD. |
| Adverse fill | At an 80% mark after 60 seconds, 5 bp and 50 bp exits lose 219.720622 and 241.311982 AUSD of principal. |
| Guard refusal and recovery | A 51 bp fill cannot satisfy the 50 bp closing limit. The position and principal survive the rejected call; restoring 50 bp at the same mark permits settlement. |
| Stale new risk | A mark aged 121 seconds fails the 120-second freshness gate; a refreshed mark permits the valid opening order. |
| Stale unwind | A frozen position refuses unwind at mark age 121 seconds. Refreshing at the adverse 60% mark permits exit and settlement. Bounty remains fixed at freeze time. |
| Correlated loss | Four admitted long loans experience the same 40% crash. Settlement exhausts reserve and junior before reaching senior. |
| FIFO withdrawal | A large unpaid head blocks a smaller payable tail. Sequential loan recovery releases the head and then the tail, with owner cash checked after each pass. |
| Price-unit boundary | Both buy and sell closing quotes pass their own guard check. The immediately adjacent out-of-band tick fails. Fixed integral/fractional examples and fuzzed marks/bands exercise both sides. |
| Causal data | Future fills cannot alter earlier marks, empty minutes carry the last mark, and missing initial or terminal coverage refuses input construction. |

### Settlement arithmetic

The small long starts with 1,000 AUSD borrower deposit, 2,000 principal,
6,000 lots, and 3x leverage. At entry, the 5 bp spread makes its price
1,000,500. Margin is 2,001 AUSD and the 4 bp entry fee is 2.401200 AUSD,
leaving 996.598800 AUSD free cash.

At an 80% mark, the 5 bp exit price is 799,600. Returned position cash is
793.680960 AUSD, giving 1,790.279760 AUSD recovered in total. The loan's
60-second interest rounds upward to 381 micro-AUSD, and the freeze bounty is
10.000001 AUSD. Principal loss is therefore 219.720622 AUSD. The 50 bp exit
returns 1,768.688400 AUSD, giving 241.311982 AUSD principal loss.

Every settlement independently checks cash recovered, bounty, interest,
principal repaid/lost, borrower residual, and reserve/junior/senior allocations.
Each scheduled step also checks:

```text
senior assets + junior assets + reserve = token cash + principal outstanding
```

## Integer quotes and genuine refusals

A sell limit must be at least `mark * (10000 - band) / 10000`. Since a price is
an integer, the lowest valid sell limit is the ceiling of that value. A buy
limit uses the floor of the upper band. `TradeGuard.closePrice` rounds both
limits inward, consistently with `checkOrders`.

At mark 979,980 with a 50 bp band, the exact lower bound is 975,080.1. A sell
limit of 975,080 is rejected; 975,081 is accepted. The retained mock rounds its
sell fills down. At a configured 50 bp spread it therefore offers 975,080,
which cannot fill a valid guard quote. That cell is an explicit execution
refusal. Its complete financial metrics are undefined, rather than zero.
The mock's pricing model is preserved.

## Retained diagnostic protocol

The study freezes three UTC dates, 2026-03-01, 2026-06-01, and 2026-09-01,
crossed with keeper intervals of 1, 15, and 1,440 minutes and exit spreads of
5 and 50 bp. These are three reused historical paths and 18 deterministic
configuration cells. They provide diagnostic coverage of this local model.
They do not form 18 independent market samples.

The initial mark is the median at the latest fill timestamp strictly before
the day begins. Each later mark is the integer midpoint median of the prior
closed minute's fills. Empty minutes carry the prior mark. Timestamp mapping
uses bounded interpolation of retained block anchors. Raw prices are
normalized to the fixture's 1,000,000 initial mark. The older worst-day study
and its existing backward-fill behavior are unchanged.

| UTC date | Fills during the day | Empty minutes out of 1,440 |
| --- | ---: | ---: |
| 2026-03-01 | 802 | 850 |
| 2026-06-01 | 2,959 | 85 |
| 2026-09-01 | 101,340 | 0 |

Acquisition coverage is checked against contiguous retained chunk names and
block-anchor bounds, separately from the last observed fill. This run does
not re-decode every raw chunk or establish independently reconciled event
completeness. Maker-fill medians and interpolated timestamps are proxies for
market marks.

The campaign seeds 40 AUSD reserve and 20,360 AUSD junior assets by closing a
one-year cash-only loan through the actual contract. Two senior lenders then
deposit 40,000 AUSD each. Four admitted synthetic borrowers each deposit
10,000 AUSD, borrow 20,000 AUSD, and take 70,000 AUSD initial notional at 3x,
alternating long and short. The first lender requests all shares; the second
requests one fortieth of its shares. Keeper passes process at most two FIFO
requests. Surviving borrowers cooperate with terminal close at the final
fresh mark, an explicit model assumption.

`H3_STEP`, `H3_SETTLEMENT`, and `H3_RESULT` log records retain per-minute state,
settlement ledgers, and complete-cell summaries. Private evidence binds the
source, input hashes, dependency versions, execution receipts, original
failures, and separate reconstruction. An aborted test's prefix logs are
diagnostic observations from a reverted scenario. They are not a completed
financial result or persistent chain state.

The retained history is labeled `diagnostic_reused`. This local mock study
provides no unseen-period, live-chain, real-loan, venue-liquidity, lender
viability, external-consumer, or adoption evidence.

## Retained diagnostic results

All 18 original cells refused terminal close because the guard rejected its own sell quote. With the guard-only repair, 9 cells completed and 9 cells refused the unchanged mock fill. All original failures and repaired outcomes remain retained.

| UTC date | Completed 5 bp cells | Refused 50 bp cells | Principal loss in completed cells |
| --- | ---: | ---: | ---: |
| 2026-03-01 | 3 | 3 | 0.000000 AUSD |
| 2026-06-01 | 3 | 3 | 0.000000 AUSD |
| 2026-09-01 | 3 | 3 | 0.000000 AUSD |

Every completed cell had zero principal loss and zero freezes. The three keeper schedules produced the same complete financial outcomes on these reused paths. These dates provide a null schedule comparison; the synthetic crash controls supply the observed schedule-sensitive loss case.

Every refused cell has undefined complete financial metrics. The separate integer reconstruction checks every completed minute, settlement, tranche balance, health value, and FIFO payout against frozen marks and raw logs. For refusals it checks the observed prefix, cash/principal identities, and the one-price-unit fill/limit mismatch.
