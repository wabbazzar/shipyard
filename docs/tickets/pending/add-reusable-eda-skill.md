# Add a reusable, evidence-first EDA skill

- **Created:** 2026-08-24
- **Owner:** wabbazzar
- **Status:** POLISHED — no open decision; auto-gate to execute-ticket
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
11. Validate the skill structurally with project-aware contract tests and
    Shipyard's real frontmatter/deck parser, then behaviorally with an
    independent synthetic EDA planning fixture. The generic Skill Creator
    `quick_validate.py` is not a valid gate for the tracked file: it rejects
    Shipyard's required `roles`, `disposition`, and `kind` keys, while
    `scripts/gen-deck-data.py:52-82` requires them. No test may reach a model,
    network, GitHub, or client data.

## Implementation plan

### Orchestration protocol

The builder is the orchestrator: delegate each implementation slice, keep only
bounded return evidence in the parent context, and personally rerun every gate
before the phase commit. No specialist manifests are installed, so use generic
subagents and do not invent a named specialist.

Every delegation brief includes this contract verbatim:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

### Phase 1 — skill contract and independent forward test (5 points)

Create the `eda` skill and only the supporting reference(s) justified by the
workflow. Add focused structural tests for discovery metadata and unfinished
scaffold content. Forward-test it against a synthetic mixed-type dataset brief
in an isolated location, reviewing whether the resulting plan exposes the
backing evidence, unavailable states, modeling boundary, and visual proof
without domain leakage or free-form conclusions.

**Delegation: subagent —** Work only in `skills/eda/` and
`tests/eda-contract.bats`. Inputs: this ticket, `skills/ui-design/SKILL.md` as
the shared-skill/frontmatter precedent, and the generic Skill Creator guidance.
Create the smallest complete skill and at most one focused reference; add
failing-first structural/behavioral fixture tests. Do not edit the installer,
deck, public docs, or commit. Return no more than 40 lines: files changed;
commands and exit codes; pre-change failing test evidence; final focused test
count; synthetic-fixture findings; blockers. Converge honestly or report the
precise blocker with the actual evidence — NEVER fake green, weaken a check, or
hand-wave "should work". Run the real command, read the real file, curl the real
port, and report exact output (exit codes, JSONL lines, HTTP codes), not
adjectives.

**Applied gate classes:** Bats, deck coupling, public-repo hygiene, delegation
contract. Config additivity, model caps, systemd, event/notify, served-app, and
live-system gates do not apply: this phase adds passive guidance and hermetic
tests only.

**Verification surface before the Phase 1 commit:**

1. Record `git status --short --branch` and `git log --oneline -3`; work only
   in the canonical checkout. The new Bats cases must fail against the
   pre-change tree because `skills/eda/SKILL.md` is absent, while any guard for
   existing skill discovery must pass before the change.
2. Run `bats tests/eda-contract.bats`; it must cover required Shipyard
   frontmatter, absence of scaffold text, neutral vocabulary, reproducibility
   contract, explicit unavailable states, evidence-backed feature/model/test
   guidance, UI visual proof, and the synthetic mixed-type request. Its
   synthetic fixture must make at least one KDE/model/test unavailable and
   assert that the plan reports why; it must not call a model, network, GitHub,
   or use client data.
3. Run `python3 scripts/gen-deck-data.py --check --root .`. Before Phase 2 adds
   `eda` to `GENERIC_SKILLS`, this proves the new frontmatter is parseable and
   reports the expected deck gap rather than a YAML/frontmatter parse failure;
   record the exact nonzero output as a known intermediate state. Do not weaken
   the deck checker.
4. Stage intent for every new file with `git add -N skills/eda
   tests/eda-contract.bats`, then run `bash scripts/leak-check.sh` and
   `git diff --check`; both exit 0. The generic Skill Creator
   `quick_validate.py` is informational only because its allowed-key list
   rejects Shipyard-required frontmatter; it is not a tracked-file gate.
5. Run the full `bats tests/`, syntax sweep from `.agents/gates.md`,
   `bash scripts/check-deck-fresh.sh`, and
   `bash scripts/ticket-lifecycle.sh --project . --check`. Except for the
   explicitly recorded completeness gap caused by a not-yet-installed skill,
   every command exits 0. Personally inspect the skill and synthetic fixture,
   then commit this independently useful source contract and tests.

### Phase 2 — installer, fleet discovery, and public deck (3 points)

Add the skill to the existing installer list and extend canonical install tests
for both discovery roots, idempotent reinstallation, owner-directory collision,
and no regression to the existing skill set. Update existing public
documentation/deck material, regenerate the deck, run the repository gate
matrix, reinstall from the canonical checkout into Maydown and Aurora, and
verify both links resolve directly to canonical `skills/eda` with no worktree
targets.

**Delegation: subagent —** Starting from the verified Phase 1 commit, work only
in `install.sh`, installer/deck Bats tests, `README.md`, `docs/INSTALL.md`,
`docs/deck-editorial.json`, and generated `docs/shipyard-data.json`. Add `eda`
to the canonical generic list; pin both discovery roots, idempotence, collision
preservation, all prior skills, nine-skill deck coverage, and authored deck
cards/graph coverage. Regenerate rather than hand-edit generated JSON. Do not
touch live project links or commit. Return no more than 40 lines: files
changed; commands and exit codes; failing-first evidence; focused test counts;
generated/deck evidence; blockers. Converge honestly or report the precise
blocker with the actual evidence — NEVER fake green, weaken a check, or
hand-wave "should work". Run the real command, read the real file, curl the real
port, and report exact output (exit codes, JSONL lines, HTTP codes), not
adjectives.

**Applied gate classes:** shell, Bats, deck coupling, public-repo hygiene,
delegation contract, and canonical live-install verification. Config additivity
does not require a new toggle because `GENERIC_SKILLS` is the established
additive install registry and the user explicitly selected fleet-wide install.
Systemd unit generation, model caps, event/notify, and served-app gates do not
apply because no unit, runner, model, event, or service is changed.

**Verification surface before the Phase 2 commit:**

1. Show the new installer/deck cases failing against the Phase 1 commit before
   the product edit. Then run
   `bats tests/eda-contract.bats tests/install-skills.bats tests/harness-install.bats tests/relink.bats tests/doctor.bats tests/uninstall.bats tests/deck-complete.bats`;
   all cases exit 0. Existing owner-directory collision fixtures must remain
   untouched and every former generic skill must still resolve byte-for-byte.
2. Run `bash -n install.sh agents/lib/*.sh agents/*/runner.sh
   agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit` and
   `python3 -m py_compile scripts/gen-deck-data.py`; exit 0. Exercise the real
   installer with hermetic project fixtures in Bats, not a network or model.
3. Run `python3 scripts/gen-deck-data.py`,
   `python3 scripts/gen-deck-data.py --check --root .`,
   `bash scripts/check-deck-fresh.sh`, and
   `bash scripts/check-deck-complete.sh`; the last reports nine installed
   skills complete. Run `node scripts/check-deck-render.mjs`; exit 0 is pass and
   exit 3 is a recorded Playwright SKIP, not a failure disguised as green.
4. Stage intent for new files, then run `bash scripts/leak-check.sh`,
   `git diff --check`, full `bats tests/`,
   `bash scripts/ticket-lifecycle.sh --project . --check`, and
   `python3 scripts/delegation-report.py --all`; record exact exit codes and
   counts. Commit only after the orchestrator personally reads all output.
5. From the canonical checkout, run `bash scripts/reconcile-skills.sh --all`
   and the installer relink for the Maydown and Aurora project directories
   resolved from their user-unit `WorkingDirectory` values. For each project,
   run `bash install.sh --relink --project "$project_dir"`, assert
   `.agents/skills/eda` and `.claude/skills/eda` are symlinks whose
   `readlink -f` equals this checkout's `skills/eda`, and assert the count of
   resolved link targets containing `/.worktrees/` is zero. Run
   `bash install.sh --doctor --project "$project_dir"`; pre-existing unrelated
   shoulder findings may remain, but output must contain no missing/broken
   `eda` finding. Re-run each relink as a dry/idempotent proof and record its
   repaired/already-current counts.
6. Graduate this ticket with
   `bash scripts/ticket-lifecycle.sh --project . --graduate
   docs/tickets/pending/add-reusable-eda-skill.md`, set status `COMPLETE`, rerun
   lifecycle/leak/diff/full gates, and include the move in the final phase
   commit. Publish the exact verified head through a review branch/PR. Because
   `.agents/config.toml` fixes `can_merge = false` and `allow_no_ci = false`,
   wait for required CI and never self-merge.

## Testing strategy

- Skill structure: project-aware frontmatter/parser validation and a focused
  test rejecting missing/invalid frontmatter or placeholder scaffolding. The
  generic Skill Creator validator's incompatible key allow-list is recorded,
  not treated as a false failure or weakened.
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

## Polishing baseline — 2026-08-24

| Surface | Command / observed result |
|---|---|
| Canonical branch | `git status --short --branch` → `main`, one ticket commit ahead of `origin/main`; no worktree checkout. |
| Full suite | `bats tests/` → 819/819 pass in 251.14 s. |
| Focused installer | `bats tests/install-skills.bats` → 5/5 pass. |
| Existing deck | freshness, completeness (8 installed skills), leak, lifecycle, diff, and render gates pass. |
| Toolchain | Bats 1.10, Python 3.12.3, Node 24.12, npm 9.2, GitHub CLI 2.83. |
| Fleet links | Maydown/Aurora have canonical `ui-design` links and no `eda` links before this change; relink dry-runs report no baseline repair. |
| Doctor | existing Maydown/Aurora shoulder findings are unrelated; neither currently has an `eda` finding because the skill is not yet installed. |
| Specialists | no `.agents/specialists/*.toml` manifests installed; generic delegation applies. |

## Ledger

| Phase | Status | Builder | Evidence |
|---|---|---|---|
| Ticket intake | complete | builder: orchestrator | User locked fleet-wide `eda`; Maydown consumes it; no open decision. |
| Polish | complete | builder: orchestrator | Gate menu/config/toolchain read; 819-test baseline and focused installer baseline green; validator incompatibility pinned. |
| Phase 1 | pending | builder: delegated subagent; orchestrator verifies | Record commit, failing-first case, focused/full counts, leak/syntax/lifecycle, and synthetic forward-test evidence here. |
| Phase 2 | pending | builder: delegated subagent; orchestrator verifies | Record commit, focused/full counts, deck result, canonical fleet links, doctors, PR/CI here. |

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
