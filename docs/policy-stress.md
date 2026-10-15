# Retrospective credit-policy stress

`python -m data.policy_stress --protocol PROTOCOL.json --output NEW_DIRECTORY`
compares the frozen approval rule with volume, raw PnL and a deterministic
SHA-256 random ordering. It consumes existing H7/H14 cohort Parquet files and
refuses an input whose SHA-256 differs from the frozen protocol. It creates a
new output directory and retains the exact protocol next to the result.

The October 2026 supplement uses the previously analyzed February to October
2026 cohorts. Development ends June 1, validation ends August 1, and the final
calendar partition ends October 9. That final partition is labeled
`diagnostic_holdout_reused`: its outcomes were previously inspected. None of
these calendar partitions establishes unseen-period or market-regime
generalization. The score and approval rule are unchanged. H7 and H14 are
separate analyses, and complete outcome intervals never overlap within an
analysis partition. Windows crossing a partition boundary are excluded.

Each baseline selects the same number of borrowers as Margin Line in each
checkpoint and fixed historical-capital band: below $250, $250 to $999.99,
$1,000 to $4,999.99, $5,000 to $24,999.99, and at least $25,000. Each policy
receives the same $90,000 modeled principal per active checkpoint, split
equally across its borrowers with deterministic integer remainders. This
matches modeled loan exposure and within-band counts, while the report retains
the unequal historical borrower-capital sums. A baseline may select the same
borrower as Margin Line. Paired trader bootstraps retain that overlap and all
repeated checkpoints; intervals are descriptive, unadjusted percentile
intervals, without a significance or improvement claim.

Observed liquidation labels feed fixed 10%, 25% and 100% loss-given-default
scenarios. A separate adversarial scenario defaults every selected borrower.
The initial pool has $1,000 reserve, $20,000 junior and $80,000 senior. Every
checkpoint starts a fresh pool. Integer micro-AUSD losses consume reserve,
then junior, then senior, matching `CreditPool`'s loss order. Results retain
each snapshot and its conservation check. Summed snapshot losses are losses
across separate deployments, not depletion of one repeatedly reused pool.
The open-loan senior cash shortfall assumes simultaneous withdrawal of all
senior assets while loans remain outstanding; it does not simulate the
contract's withdrawal queue.

These are empirical-input scenarios, not measured lender losses. The data
does not identify actual loan principal, recoveries, interest, fees, mark
paths, keeper timing or execution slippage. The supplement does not assign
invented keeper-delay or adverse-fill effects to the liquidation flags.
Existing contract and worst-day stress evidence remains separate.
The fixed exposure allocation does not enforce `CreditManager`'s per-line
capital cap, collateral leverage limits or score-proof terms. In checkpoints
with few approvals it may exceed those limits. It is an accounting stress
scenario, not a replay of contract-admissible lending decisions.

The source cohort includes traders active after the checkpoint. Inactive
applicants and terminally censored outcomes are absent, never treated as
nondefaults. `new_to_prior_cohort` means an account absent from earlier
checkpoint rows, not a newly created exchange account. Both this cohort and
the full cohort retain unique-trader and trader-checkpoint denominators.
Neither risk separation nor an AUC establishes credit viability or causality.
