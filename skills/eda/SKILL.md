---
name: eda
description: >
  Plan, build, or review reproducible exploratory data analysis when a dataset
  needs typed profiles, distributions, relationships, feature evidence,
  interpretable modeling, statistical tests, or notebook-style analytical output.
roles: [design, build, release, human]
disposition: adapted
kind: shared
---

# eda

Build analysis as an inspectable chain from data to claim. Prefer compact
tables, plots, and mechanically derived statements over free-form narrative.

## Declare the analytical contract

Before calculating, record:

- the question or decision, target if any, and what would answer it;
- the typed schema, units, identifiers, time/order semantics, and expected keys;
- the population and slice, exclusions, comparison groups, and observation unit;
- privacy constraints and whether row-level output is permitted; and
- whether the work is descriptive association, inferential evidence,
  prediction, or a causal study. Do not let one kind of claim stand in for
  another.

Declare types from the source contract. Do not infer that a column is boolean
only because its observed values happen to be `0` and `1`; name the allowed
tokens and preserve invalid tokens as visible issues.

If the target, observation unit, join grain, time order, or privacy boundary is
ambiguous enough to change the result, resolve it before proceeding.

## Make the run reproducible

Create a compact reproducibility record beside the outputs. Include a
privacy-safe source fingerprint, source identifiers, row and column counts,
filters, joins, deduplication and ordering rules, analysis timestamp and
software versions, method parameters, and a deterministic seed where
randomness is used.
Record input validation failures rather than repairing them invisibly.

Treat each table or figure as an evidence unit. Give it a named backing frame,
population/slice and `n`, units, and missing and excluded counts. Record the
method and parameters. Include uncertainty when applicable and a limitation or
unavailable state. Keep the backing frame available for value-level
verification.

Never invent, silently impute, or silently drop data. If a transformation,
imputation, exclusion, weighting rule, or pairwise deletion is justified,
label it and retain the before/after counts.

For ordered state-change features, retain the level and the change. Declare the
state grain and ordering key; compute `delta = current state - immediately
prior state`; retain the prior-state key; and leave the first state or either
missing operand unavailable, never zero. Do not cross groups or manufacture a
batch/lot identity that the source cannot support.

## Profile columns by type

Start with one schema/profile table so later work uses the same definitions.

- Numeric: count, missing, distinct, mean, median, meaningful mode and mode
  frequency, standard deviation, robust spread, min, selected quantiles
  including p95, max, skew, kurtosis, units, and invalid/non-finite counts.
- Categorical/boolean: count, missing, distinct, mode, mode frequency,
  level counts/shares, and a declared rare-level rule.
- Datetime/ordered: valid range, resolution, gaps or duplicates relevant to the
  observation unit, and sorting policy.
- Identifier/free text: cardinality and validity checks, not numeric summaries
  or automatic model features.

Preserve unavailable rather than coercing an undefined statistic to zero.

## Inspect distributions and relationships

For numeric distributions, pair tabular quantiles with a histogram and ECDF.
Add KDE only when the declared minimum sample size, finite support, and
non-constant variance make smoothing defensible. Otherwise show `unavailable`
with the failed condition. Disclose bin and bandwidth choices.

Build covariance and correlation evidence from the declared eligible columns.
Publish the matrix together with pair counts and the missing-data policy;
constant columns, inadequate pairs, nonlinear structure, and multiple scans
must remain visible. Use plots appropriate to the types and density of points,
and do not describe association as causal.

Derive default relationship fields mechanically from a published ranked table
on the visible population. State the association measure, target, pair counts,
missingness, direction, tie-break, and number retained. Do not use covariance
to rank defaults across unlike units; keep it available as a scale-dependent
view.

When detailed method selection is needed, read
[references/methods.md](references/methods.md). It defines minimum evidence and
failure states without prescribing a library or estimator.

## Recommend target features transparently

If there is a target, produce a ranked evidence table rather than a bare score.
For every candidate disclose type, eligibility, missingness, leakage screen,
effect or association measure with direction and uncertainty when supported,
redundancy/collinearity evidence, temporal availability, and the exact reason
it was recommended or rejected. Apply the ranking rule deterministically and
state it.

Feature recommendation is a modeling input, not proof of mechanism. Exclude
post-outcome values, direct encodings of the target, unstable identifiers, and
features unavailable at the intended prediction time.

## Fit only interpretable, supported models

Choose a baseline that matches the target type and analytical question. State
the split or resampling policy, preserving time and groups where needed. Show
baseline comparison, coefficients or effects, uncertainty where available,
actual versus predicted evidence, residual or error diagnostics, and
out-of-sample metrics with units. Check missingness, leakage, collinearity,
support, and material assumption failures.

When screening ordered candidates such as lags, horizons, or windows, separate
`best tested` from `supported`. The lowest candidate error is supported only if
it beats the declared same-fold baseline. An unsupported best-tested candidate
may anchor explicitly exploratory analysis, but must not be called selected,
causal, residence time, or an operating recommendation. If domain reasoning
expects transitions to matter, review both state levels and declared
state-change features with train-only inclusion/exclusion reasons.

No particular estimator is universal. If the project omits a model family or
the data cannot support a defensible fit, report the model as unavailable and
continue with supported descriptive evidence.

## Test hypotheses with effects

For each statistical test, name the hypothesis, variables, comparison and
sampling unit, assumptions/checks, sample sizes, missing/exclusion policy,
test statistic, effect size, uncertainty interval, raw p-value, multiplicity
policy and adjusted p-value when applicable. Prefer an unavailable state to a
test whose support or assumptions are materially inadequate. A p-value alone
is never the result.

## Present an executable analysis

Arrange the output in notebook order: one question, one method label, one
backing table or plot, then one short deterministic interpretation computed
from displayed values and limitations. Use explicit templates such as
“For {slice} (n={n}), {estimate} was {value} {units}; {limitation}.” Suppress
the sentence when its required value is unavailable. Never ask a generative
model to improvise conclusions.

For UI-bearing EDA, inspect the real rendered result at every declared
responsive viewport. Verify readable contrast, keyboard operation, visible
focus, visible scrolling and overflow behavior, reduced-motion handling where
relevant, and agreement between plotted/table values and backing values.
Capture the checked states and revise the largest mismatch before delivery.

Use exactly one document-level vertical scroll owner and no custom duplicate
rail. Keep its track and thumb persistently visible. Page-level horizontal
overflow is a failure; bounded table overflow does not authorize another
document scrollbar.

Put each analytical selection control immediately before its result plot. In
rendered QA, interact with every declared choice and assert that the actual
control rectangle and full plot rectangle are both inside one viewport. A
union-height-only check is insufficient because both boxes may still be partly
off-screen.

Bound nontrivial tables with stable pagination or a compact first page. Exercise
default, last, and return-to-first pages; verify row boundaries and at least one
displayed cell against the backing frame. Put wide or long backing detail in a
collapsed local disclosure instead of expanding the whole document.

For data-quality counts, provide a collapsed local issue inspector beside the
summary. When opened, show only a stable row/source index, the problem field,
offending value, reason, and minimal key context. Mark the offending value cell
in accessible red and pair color with a textual reason. Keep raw values closed
by default and use synthetic issue rows for rendered capture artifacts.

## Verify before handoff

- Re-run from the declared inputs in a clean or controlled environment.
- Check row counts and representative backing values across transformations,
  tables, plots, interpretations, and model/test results.
- Exercise missing, constant, tiny-sample, invalid, and no-target paths.
- Record which outputs are unavailable and why; do not present absence as zero.
- Assert one document scroll owner, no page-level horizontal overflow, and
  actual control/result co-visibility at every declared viewport.
- Exercise table first/default/last pages and private-by-default local issue
  disclosures with synthetic open-state evidence.
- For ordered candidates, publish candidate error, baseline error, improvement,
  spread from best tested, and support state; test supported and unsupported
  paths.
- Run the consuming project's data, unit, integration, privacy, and rendered-UI
  gates. Publishing, external data transfer, or a new dependency still needs
  the authorization required by that project.
