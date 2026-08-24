# Method selection and evidence floors

Use this reference when an EDA needs conditional method choices. Declare the
selected rule and threshold in the reproducibility record; these are decision
criteria, not fixed universal cutoffs.

## Column and distribution evidence

For numeric columns, report count, missing, distinct, units, mean, median,
meaningful mode and mode frequency, standard deviation, IQR or MAD, min, p05,
p25, p75, p95, max, skew, kurtosis, and invalid/non-finite counts. A mode may be
`unavailable` for effectively continuous values. For categorical columns,
report count, missing, distinct, mode, mode frequency, levels/shares, and the
declared rare-level threshold.

Choose histogram bins with a named rule or explicit width. An ECDF is useful
without a smoothing assumption. A KDE needs enough finite observations and
non-constant spread for the declared kernel and bandwidth; record `unavailable`
for tiny samples, constant values, or unsupported bounds rather than drawing a
curve that implies evidence the data do not contain.

## Relationship evidence

Select measures by type and question: covariance retains scale, Pearson
correlation summarizes linear numeric association, Spearman correlation ranks
monotonic association, and type-appropriate contrasts or contingency measures
serve mixed/categorical pairs. Publish pair counts beside every matrix and
state whether complete-case, pairwise deletion, imputation, or another explicit
missing-data policy was used. Show constant columns, insufficient pairs, and
uncertainty as unavailable cells, not zeros.

For broad scans, disclose multiplicity and avoid ranking noisy estimates only
by magnitude. Plots should expose shape, outliers, density, groups, and time
order that a single coefficient can hide.

## Feature recommendation evidence

A ranked evidence table should contain candidate, type, eligibility, observed
and missing counts, leakage/temporal-availability result, association or effect
with direction, uncertainty or stability evidence, redundancy/collinearity,
recommend/reject status, and a mechanically derived reason. Establish ranking
and tie-breaking rules before viewing the final order. Review proxy and privacy
risk separately from predictive evidence.

## Interpretable model evidence

Match the baseline and metric to the target type and decision. Preserve groups
or chronology in the split or resampling policy. Report training/test support,
baseline comparison, coefficients or marginal effects with scale and coding,
uncertainty when available, actual versus predicted results, residual or error
diagnostics, and limitations. Never interpret an importance, coefficient, or
prediction as causal without a causal design.

Mark modeling unavailable when target support, class/group support, valid
features, temporal availability, or a critical assumption is inadequate. A
project may require or omit particular model families; do not add one simply
to complete a checklist.

## Statistical-test evidence

Choose the test only after defining the null/alternative hypothesis, sampling
unit, paired/independent structure, variable types, and assumptions. Report
sample sizes, exclusions, statistic, effect size, uncertainty interval, raw
p-value, multiplicity family and correction, adjusted p-value, and assumption
checks. Prefer robust, permutation, or exact procedures only when their own
conditions are satisfied. Otherwise make the test unavailable and explain the
failed condition.
