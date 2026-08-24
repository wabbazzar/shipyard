# Add a reusable, evidence-first EDA skill

- **Created:** 2026-08-24
- **Owner:** wabbazzar
- **Status:** Draft — ready for polish-ticket
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 8 (two phases: 5 · 3)
- **Refs:** confirmed Maydown EDA rebuild scope; `skills/ui-design/SKILL.md`;
  `install.sh:197,1559-1593`; `tests/install-skills.bats:40-100`;
  `.agents/gates.md`

## Goal

Shipyard supplies one fleet-wide `eda` skill that guides agents to build
reproducible exploratory analyses from typed data evidence: column profiles,
distributions, relationships, target-feature recommendations, interpretable
models, statistical tests, and visually verified notebook-style output. A
reinstall makes the same source skill discoverable from both Codex and
Claude/Hermes roots in Maydown, Aurora, and every other installed project.

## Problem / background

Shipyard currently installs eight generic workflow/design skills from the
single `GENERIC_SKILLS` list at `install.sh:197`, linking each source into both
project discovery roots at `install.sh:1559-1593`. None gives data-analysis
agents a shared contract for reproducible EDA. Projects therefore rediscover
summary statistics, missing-data handling, feature relevance, model
interpretation, inferential caveats, and rendered proof independently.

The motivating Maydown rebuild requires the same sequence used by the owner's
teaching material: column summary, distribution drilldown, covariance and
target relationships, interpretable regression, and statistical tests. The
skill must capture that reusable analytical discipline without baking in
Maydown columns, FPY, Streamlit, a particular model library, client data, or the
decision-tree omission selected for that app.

## Confirmed decisions

| Decision | Result |
|---|---|
| Scope | Fleet-wide shared skill, not a Maydown-local `.agents` file. |
| Name | `eda`, matching the confirmed shortest discoverable name. |
| Invocation | Normal automatic discovery; explicit `$eda` remains available. |
| Analysis stance | Evidence and backing frames first; prose is limited to method labels, limitations, and deterministic interpretations derived from displayed values. |
| Portability | Dataset-, target-, framework-, and domain-neutral. Projects provide their own schema, privacy rules, viewports, and gate commands. |
| Modeling | Require interpretable, target-appropriate baselines and diagnostics; do not universally require or prohibit a tree because that is a project decision. |
| Packaging | Follow the existing single-source symlink model and regenerate the deck after adding the generic skill. |

### Open decisions with defaults

None.

### User-decision class

None. The owner explicitly selected fleet-wide installation and the `eda`
route. The skill is passive guidance; it adds no scheduled job, model call,
notification, public endpoint, destructive action, or data transfer.

## Boundaries

### Always

- Start from a declared analytical question, target (if any), typed schema,
  population/slice, exclusions, and privacy constraints.
- Make every statistic and plot reproducible from a named backing frame and
  disclose sample size, missingness, method, parameters, and uncertainty.
- Separate descriptive association, inferential evidence, prediction, and
  causal claims.
- Choose type-appropriate summaries and tests; state when small samples,
  constant columns, missingness, collinearity, leakage, or invalid assumptions
  make a result unavailable.
- Require real rendered critique for UI-bearing EDA, including contrast,
  keyboard focus, scrolling/overflow, responsive viewports, and backing-value
  agreement.

### Ask first

- Sending data or row-level values to an external service.
- Introducing a top-level runtime/model dependency into a consuming project.
- Choosing a domain threshold that changes a continuous target into classes.
- Publishing an analysis or changing a live deployment.

### Never

- Invent values, silently impute, silently drop rows, or present unavailable
  evidence as zero.
- Generate free-form AI conclusions that are not mechanically tied to displayed
  statistics and limitations.
- Treat correlation, feature importance, coefficients, or p-values as causal
  proof.
- Bake Maydown/Aurora field names, a Streamlit component tree, or a particular
  estimator into the shared skill.
- Create a parallel skill registry or per-harness fork; preserve the canonical
  `skills/` source and installer-owned links.

## Technical requirements

1. Create `skills/eda/SKILL.md` with concise, discriminating frontmatter and a
   progressive workflow covering analytical contract, reproducibility record,
   type-aware column profiling, distribution diagnostics, relationship and
   target analysis, feature recommendation, interpretable modeling,
   statistical tests, output design, and verification.
2. Keep reusable method-selection details in a focused reference only if they
   materially reduce the entrypoint. Do not add placeholder resources,
   duplicated tutorials, README files, or app templates.
3. Define observable output contracts rather than fixed prose: backing tables,
   slice and `n`, units, missing/excluded counts, method/parameters, deterministic
   seed where relevant, effect size/uncertainty, multiplicity policy, and a
   limitation/unavailable state.
4. Define numeric summaries including count, missing, mean, median, mode where
   meaningful, standard deviation, min/max, selected quantiles including p95,
   skew, and kurtosis; categorical summaries include count, missing, distinct,
   mode, frequency, and rare-level disclosure.
5. Route numeric distribution work through histogram/ECDF and KDE only when
   sample size and variance support it. Constant/tiny samples produce an
   explicit unavailable reason rather than a misleading curve.
6. Require covariance/correlation matrices with pairwise sample counts and an
   explicit missing-data policy. Target-feature recommendations must be a
   ranked evidence table that discloses eligibility, leakage screening,
   missingness, effect/association measure, redundancy/collinearity, and why a
   feature was recommended or rejected.
7. Require interpretable baselines appropriate to the target, with split or
   resampling policy, coefficients/effects, uncertainty where available,
   actual-versus-predicted evidence, residual/error diagnostics, and honest
   limitations. A model not requested by the project is not mandatory.
8. Require statistical tests to name hypotheses, assumptions, sample sizes,
   effect sizes, uncertainty, multiplicity handling, and an unavailable state;
   p-values alone are insufficient.
9. Add `eda` to the canonical installer skill list, extend hermetic installer
   coverage for both discovery roots and existing-owner collision behavior,
   and preserve all existing skills byte-for-byte.
10. Update the canonical README/deck claim and regenerate the generated deck
    data as required by `.agents/config.toml:118-129` and `.agents/gates.md`.
11. Validate the skill structurally with Skill Creator's validator and
    behaviorally with an independent, synthetic EDA request in an isolated
    temporary project; no test may reach a model, network, GitHub, or client
    data.

## Implementation plan

### Phase 1 — skill contract and independent forward test (5 points)

Create the `eda` skill and only the supporting reference(s) justified by the
workflow. Add focused structural tests for discovery metadata and unfinished
scaffold content. Forward-test it against a synthetic mixed-type dataset brief
in an isolated location, reviewing whether the resulting plan exposes the
backing evidence, unavailable states, modeling boundary, and visual proof
without domain leakage or free-form conclusions.

**Delegation:** subagent — create the skill contract and supporting reference,
run structural validation, and return the synthetic forward-test artifacts and
specific shortcomings for revision.

High-level proof: Skill Creator validation, focused skill tests, leak firewall,
and an independent behavioral critique all pass.

### Phase 2 — installer, fleet discovery, and public deck (3 points)

Add the skill to the existing installer list and extend canonical install tests
for both discovery roots, idempotent reinstallation, owner-directory collision,
and no regression to the existing skill set. Update existing public
documentation/deck material, regenerate the deck, run the repository gate
matrix, reinstall from the canonical checkout into Maydown and Aurora, and
verify both links resolve directly to canonical `skills/eda` with no worktree
targets.

**Delegation:** subagent — implement the installer/tests/deck slice from the
verified Phase 1 contract and return exact install/link/deck evidence; the
orchestrator retains live fleet relink and final full-gate responsibility.

High-level proof: installer hermetic tests, syntax, full Bats, leak, deck
freshness/completeness/render, canonical-checkout symlink audit, and read-only
doctor checks pass.

## Testing strategy

- Skill structure: Skill Creator quick validation and a focused test rejecting
  missing/invalid frontmatter or placeholder scaffolding.
- Skill behavior: independent synthetic mixed-type request; inspect its actual
  analysis plan and outputs for reproducibility, type handling, unavailable
  states, and non-causal language.
- Installation: `tests/install-skills.bats` proves both discovery roots,
  idempotency, collision preservation, and all prior generic skills.
- Repository: canonical Bats, shell/Python syntax, leak firewall, deck
  freshness/completeness, optional deck rendering, and lifecycle gates.
- Live install: dry-run, canonical relink, doctor, and direct symlink resolution
  for Maydown and Aurora; do not invoke any scheduled agent or model.

## Definition of Done

- [ ] `skills/eda/SKILL.md` is concise, valid, automatically discoverable, and contains no project-specific fields or framework assumptions.
- [ ] The workflow produces a reproducibility record plus type-aware column, distribution, relationship, feature, model, and statistical-test evidence with explicit unavailable states.
- [ ] Outputs require backing frames, slice/`n`, missing/excluded counts, method/parameters, uncertainty/effect size, and limitations; unsupported AI narrative and causal language are prohibited.
- [ ] Numeric profiles cover mean, median, meaningful mode, p95, spread, skew, kurtosis, and missingness; categorical profiles cover mode/frequency/cardinality/rare levels.
- [ ] KDE, covariance/correlation, target-feature ranking, interpretable modeling, and statistical tests have method-selection and failure-state guidance.
- [ ] UI-bearing analyses require contrast, visible scrolling, keyboard/focus, responsive, and backing-value visual proof.
- [ ] Independent synthetic forward-testing finds no domain leakage and demonstrates the intended behavior.
- [ ] `eda` installs idempotently into both discovery roots without clobbering project-owned directories or changing existing skills.
- [ ] Maydown and Aurora resolve their installed `eda` links directly into the canonical Shipyard checkout, with zero worktree-linked skills.
- [ ] Full Bats, syntax, leak, deck, lifecycle, delegation, diff, and doctor gates pass; generated deck data is current.
- [ ] The exact verified head is published through the repository's normal review flow without self-merge.

## Dependencies

- Confirmed owner scope for the Maydown rebuild and fleet-wide skill: satisfied.
- Consumed by Maydown Ticket 003 after this skill is installed.

## Risks and mitigations

- **Risk:** the skill becomes a statistics textbook. **Mitigation:** keep the
  entrypoint decision-focused; route only genuinely conditional method detail
  to one focused reference.
- **Risk:** Maydown preferences become universal rules. **Mitigation:** forward-
  test on a neutral synthetic dataset and prohibit project-specific fields,
  framework structure, and estimator mandates.
- **Risk:** adding a generic skill repoints fleet links incorrectly.
  **Mitigation:** work only in the canonical checkout, run installer collision
  tests, relink from canonical main, and assert zero worktree targets.
- **Risk:** vague visual guidance repeats the rejected first pass.
  **Mitigation:** require measurable contrast/focus/scroll/viewport and
  backing-value checks whenever the consuming deliverable has a UI.

## Out of scope

- Building Maydown's application UI or analytical functions.
- Shipping a shared Python EDA package or forcing one plotting/model library.
- Running an analysis against client data from Shipyard tests.
- Adding a decision tree, classifier threshold, causal model, or generative
  narrative engine to any project.
