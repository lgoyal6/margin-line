# Retrospective temporal validation

`python -m data.temporal_validation` analyzes the frozen checkpoint cohorts with
a calendar split, conservative outcome-window purging, trader-clustered intervals,
development-only risk calibration and within-checkpoint capital matching.

This is a retrospective robustness check on history that was already inspected.
It does not establish prospective performance, causal credit-policy effects or
actual lending losses. The input cohorts condition on traders continuing to trade
after the decision checkpoint. That future-activity condition would not be known
when deciding whether to offer a loan.

## Protocol

The split was frozen before this run's temporal summaries:

- Cutoff: August 1, 2026 at 00:00 UTC.
- Development: the complete outcome window must end before the cutoff. Archived
  checkpoints contain only dates, so reserve an additional day conservatively.
- Evaluation: checkpoint starts at or after the cutoff. Cross-boundary rows are
  explicitly purged.
- The existing score/approval rule stays fixed. A two-parameter logistic mapping
  from score to risk is fit using development outcomes only. Compare its Brier
  score with a constant development-period liquidation prior.
- Report score, volume and raw-PnL discrimination inside each checkpoint before
  averaging. Pooled rankings across time are not the primary comparison.
- Resample whole traders for uncertainty. This accounts for recurring accounts;
  it does not account for shared market shocks across different traders.
- Match approvals to experienced denied traders at the same checkpoint, without
  reuse, by nearest log-capital distance within a fixed factor-of-two caliper.
  Report unmatched approvals and matching gaps. This is historic-deposit matching,
  not matched actual loan exposure or a causal experiment.
- Report traders seen and not seen in development separately. A trader absent
  from development can still have trading history in its score features.

The uncertainty helper is recovered from existing commit
`f953ff6adda44b36217bd3a86ecb062cc2c674d6`; the temporal analysis extends that
work instead of replacing its evidence.

## Reproduce

Install the existing exact pins in `data/requirements.txt` and use the archived
cohort parquet with account, checkpoint, policy, score, capital and outcome
columns. Inputs and outputs belong in private working state:

```sh
python -m data.temporal_validation \
  --cohort "$COHORT_H7" --horizon-days 7 \
  --cutoff 2026-08-01T00:00:00+00:00 \
  --output "$STUDY_OUTPUTS/analysis-h7.json" --draws 2000
```

Repeat with the H14 cohort and `--horizon-days 14`. The runner records input and
source hashes and refuses to overwrite results. It does not download history,
retrain the credit rule, change deployment records or send transactions.

## Recorded October 31, 2026 checks

| Metric | 7-day horizon | 14-day horizon |
| --- | ---: | ---: |
| Development rows | 7,580 | 6,715 |
| Purged rows | 1,340 | 3,153 |
| Evaluation rows | 6,253 | 6,385 |
| Evaluation traders | 1,710 | 1,706 |
| Approved liquidation rate | 4.29% | 6.88% |
| Denied liquidation rate | 15.47% | 23.61% |
| Approved-minus-denied, trader-bootstrap 95% interval | [-13.50, -8.45] percentage points | [-20.87, -12.54] percentage points |
| Macro-checkpoint AUC, Margin Line | 0.673 | 0.670 |
| Macro-checkpoint AUC, volume | 0.538 | 0.534 |
| Calibration Brier | 0.1213 | 0.1663 |
| Constant development-prior Brier | 0.1279 | 0.1777 |
| Matched approval/denial pairs | 317 | 312 |

The positive association survives these checks. Calibration is not solved:
seven-day mean predicted risk was 12.71% versus 14.89% observed. Do not describe
the system as accurately calibrated merely because its Brier score is below the
constant-prior baseline.

All 43 scorer/risk Python tests passed. A broader underwriter test run needs the
large archived event dataset, which is absent from this isolated worktree. Its
same three data-dependent failures were reproduced on an unchanged base worktree;
they were not suppressed or counted as passing. No contract or deployment code
changed, and no chain transactions were sent.

Still open: a genuinely new future data window, verified applicant eligibility
without future-activity conditioning, calendar-shock uncertainty, and an economic
loss comparison using actual or explicitly simulated deployed exposures.
