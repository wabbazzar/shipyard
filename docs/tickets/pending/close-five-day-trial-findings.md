# Close the five-day fleet trial findings and make the floors auditable

- **Created:** 2026-08-04
- **Owner:** wabbazzar
- **Status:** Implemented through Phase 3 — Phase 4 awaits a real third usage project
- **Priority:** high
- **Type:** chore
- **Estimated Points:** 13 (Phase 1: 3 · Phase 2: 3 · Phase 3: 5 · Phase 4: 2)
- **Refs:** `README.md:182-205`, `docs/index.html:439-450`,
  `docs/deck-editorial.json` phase id `12`,
  `skills/shipyard/inspect.py:1544-1673,2076-2200,3204-3356`,
  `dashboard/operator.py:57-66,551-605`,
  `agents/design/collectors.sh:9-24,80-169`,
  `agents/lib/outcome-lineage.sh:4-140`,
  `agents/design/runner.sh:452-466`, `agents/build/runner.sh:344-407`,
  `agents/release/runner.sh:580-599`, `skills/install/SKILL.md:86-126`,
  `docs/INSTALL.md:87-109`, `tests/shipyard-inspect.bats:2520-2590`,
  `tests/design.bats:49-131`, `dashboard/tests/test_operator.py:1855-1865`

## Goal

Publish the honest result of the original five-day fleet trial, close each
miss through the routing rule, and make the next trial mechanically auditable
without manufacturing historical evidence.

The result must be consistent in the trial's owner ticket, Shipyard README,
public presentation, Daily Dispatch, fleet inspector, and operator dashboard.
Unset configuration remains byte-for-byte compatible with today's behavior.

## Context and evidence freeze

### Authoritative window

The trial belongs to Phase 12 of Ice's
`docs/tickets/pending/quartet-gaps-guardian-teeth.md`, not to the later rolling
inspector snapshot. Its fixed half-open window is:

```text
[2026-07-22T00:00:00Z, 2026-07-27T00:00:00Z)
```

The five ledger days are July 22–26. Evidence transported later is admissible
only when its immutable source timestamp falls inside this window. Activity
performed after the window never changes the result.

### Work Mac reconciliation

The delayed handoff is complete and does not change the trial verdict:

- `/tmp/workmac-shipyard-293a654.bundle` verified at SHA-256
  `30f374658c1c754145289fc04d53643adaf4e872081fc28c1bf7137c35749666`
  with original tip `293a654fda5becadafa2b3b6f1781fe735a78ef2`.
- PR #17 carried the 24 commits at exact head
  `493a6e23ded3318b1c0f39671aec84215e53a0a8`; all six checks passed and it
  merged as `ab15f11577b3454823ce0371ece9d8dfe86e20cb` on 2026-08-04.
- Original bundle author dates run from 2026-08-03 through 2026-08-04. They are
  all after the original July 22–27 trial and therefore provide current system
  context only, not trial credit.

### Final adjudication

| Floor | Result | Minimal sufficient evidence |
|---|---|---|
| T1 — bugs caught and fixed | **PASS (≥1)** | `bopthere-suk` classified incident `ac47c536…` as a regression at `2026-07-22T04:21:34Z`; mentat opened bug `mentat:bopthere:e639f832` at `04:46:17Z`; the Dispatch recorded Wesley's approve at `20:27:16Z`; Shipyard commit `d78cb749fd127ba4f29d0ab0a3ad11c3db25ca3d` fixed the false failed-unit/medic-freeze loop at `20:55:05Z` and its ticket records the live unit/medic proof. |
| T2 — usage assessed | **MISS (2/3)** | In-window retained beacons contain 387 Aurora records and 52 Shredly records; Bopthere and Starbird contain zero. The Dispatch implementation reads `<project>/data/usage/*.jsonl`, so only two projects could produce real-telemetry assessments. Beacon code or request traffic alone does not count. |
| T3 — feature shipped end to end | **MISS (0)** | The only in-window `type=feature` proposal was `mentat:shipyard:8aa6334e` at `2026-07-24T10:00:50Z`. Its implementation commit `ab0ef6d78f7818a8d2dc68355bacbe13e1b26acd` is timestamped `22:01:31Z`; its project decision line is later at `22:05:12Z`, and no in-window `news.action` stamp exists for it. Build-before-stamp is not proposal → stamp → build, so it receives no credit. |
| T4 — consequential human decision | **PASS (≥1)** | The `mentat:bopthere:e639f832` fleet-live runner change remained held until Wesley approved it in the Dispatch at `2026-07-22T20:27:16Z`; the fixing commit followed at `20:55:05Z`. This changed fleet-wide alert/freeze behavior and was neither defaulted nor auto-merged. |

The final trial result is **2/4 floors met**. T2 and T3 are written findings,
not qualified passes.

The later read-only command
`bash .agents/skills/shipyard/shipyard.sh inspect --days 5 --json` captured at
`2026-08-04T19:13:34Z` reported 8 projects and kept all four historical floors
`partial`: usage components were 2 projects/1571 records, but the inspector
still lacks the explicit outcome chains required to make a measured claim.
That rolling result is a baseline for this follow-up, not the original trial.

## Decisions

### Locked

| Decision | Resolution and rationale |
|---|---|
| Trial boundary | Use `[2026-07-22T00:00:00Z, 2026-07-27T00:00:00Z)` permanently. Never move the window to improve the result. |
| Historical result | Publish T1 pass, T2 miss, T3 miss, T4 pass: 2/4. No synthetic or backdated event may alter it. |
| Late evidence | Admit only immutable source timestamps in the fixed window; transport/integration timestamps are context. |
| Usage floor | Require a declared source, at least one real non-zero beacon in-window, and a `kind=usage` assessment in the Daily Dispatch. Instrumentation code, HTTP traffic, or an empty directory does not count. |
| Installer routing | Add optional `[design].usage_path`, a project-relative directory. Unset resolves exactly to `data/usage`; absolute paths, `..`, non-strings, and unreadable configured paths are explicit bad/unavailable coverage. |
| Prospective lineage | Extend the existing opt-in `[telemetry].outcome_lineage`; do not create a second switch. False/unset preserves legacy event bytes exactly. |
| Privacy | Persist only stable opaque IDs, project ID, timestamps, enum classifications, non-negative counts, and Git object IDs. Never persist prompts, reasons, ticket prose, user content, filesystem paths, or result bodies. |
| Public closeout | The owner explicitly requested that the presentation and README be made current. Publish the aggregate 2/4 result and follow-up link; keep private evidence out of public copy. |
| Dashboard contract | Keep schema-v1 promise IDs and current `partial`/`measured` and `unverified`/`verified`/`violated` meanings stable. |
| Cross-repo history | Update only the Phase 12 rows in Ice's owner ticket. Its existing local commits are unrelated and must not be amended, squashed, or pushed as a side effect. |

### Open with defaults

None.

### User-decision class

None. The public README/presentation closeout is explicitly authorized by the
owner's request. Shipyard's existing human stamp and `can_merge=false` remain
the merge boundary for automation.

## Design record

- **Subject:** a time-bounded operational trial and the difference between
  observed components and proven outcomes.
- **Audience/job:** an evaluator or fleet operator must see in seconds what
  passed, what missed, and where the repair is tracked.
- **Thesis:** put the 2/4 result directly beside the four promises; use precise
  pass/miss language and evidence links, with no celebratory styling that could
  make a miss read as success.
- **Hierarchy:** result first, four-row outcome second, follow-up third; the
  criteria remain visible as the interpretation key.
- **Visual system:** reuse the deck's existing Hull surface, Chalk text, Signal
  accent, status colors, typography, spacing, and table treatment. Add no new
  color or type role.
- **Signature element:** the existing four-row trial table becomes the single
  result ledger by adding a Result column; do not add a competing card.
- **Responsive behavior:** at `1440×900` the full ledger is scannable without
  overlap; at `390×844` labels and evidence copy wrap without horizontal
  overflow or clipped links.
- **Interaction/accessibility:** semantic table headers remain intact; links
  are keyboard reachable with existing focus styles; no motion is added.

`ui-design` review found no need for a new visual system. The largest risk is
semantic—an ambiguous “qualified” state would hide a miss—so the copy uses only
PASS and MISS for the historical result.

## Specialist routing result

Polish discovery on 2026-08-04 found no `.agents/specialists/*.toml` in this
project. No specialist manifest matched or required invocation; the normal
polish flow applies unchanged.

## Orchestration protocol

The builder is the orchestrator: delegate bounded implementation slices, keep
the primary context lean, and personally re-run every declared gate before each
commit. Every delegated brief includes this clause verbatim:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

## Phase 1 — Publish the historical finding (3 points)

### Slice

1. Update only Phase 12's daily/sign-off rows and roll-up checkbox in Ice's
   `docs/tickets/pending/quartet-gaps-guardian-teeth.md` with the frozen 2/4
   evidence above. Do not rewrite other phases or push Ice's unrelated commits.
2. Add the aggregate result and this follow-up link to `README.md`.
3. Change the public trial table in `docs/index.html` into criterion/floor/result
   form; update phase id `12` in `docs/deck-editorial.json` to completed with
   `T1 PASS · T2 MISS (2/3) · T3 MISS · T4 PASS`; regenerate
   `docs/shipyard-data.json` with `python3 scripts/gen-deck-data.py`.
4. Add a source/render assertion that the 2/4 result and both misses exist once,
   table markup remains valid, and narrow rendering has no overflow.

### Verification

Run from Shipyard unless a command names Ice:

```bash
python3 scripts/gen-deck-data.py
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
bats tests/deck-render.bats
bash scripts/leak-check.sh
bash scripts/ticket-lifecycle.sh --project . --check
git diff --check
git -C ~/code/wabbazzar-ice diff --check -- docs/tickets/pending/quartet-gaps-guardian-teeth.md
```

Inspect the rendered deck at `1440×900` and `390×844`; record the result table,
no horizontal overflow, no console/page errors, and browser cleanup. No service,
notification, or event mutation applies in this phase.

**Observable DoD:** README and the rendered presentation both say 2/4 with T2
and T3 marked MISS; generated data is fresh; the Ice owner ticket has five
filled days plus an honest sign-off/finding row; all commands above exit 0.

**Delegation: subagent — public closeout review.** Read only the frozen evidence
table, `README.md`, `docs/index.html`, `docs/deck-editorial.json`, and
`scripts/check-deck-render.mjs`. Return ≤40 lines: files reviewed; exact copy or
markup contradiction; commands run + exit codes; rendered viewport evidence;
blockers. Do not edit the Ice ticket or Git history. Converge honestly or report
the precise blocker with the actual evidence — NEVER fake green, weaken a
check, or hand-wave "should work". Run the real command, read the real file,
curl the real port, and report exact output (exit codes, JSONL lines, HTTP
codes), not adjectives.

## Phase 2 — Declare real-usage sources and close the routing gap (3 points)

### Slice

1. Add red-first cases in `tests/design.bats` and `tests/shipyard-inspect.bats`
   for `[design].usage_path`: unset default, valid project-relative directory,
   invalid absolute/escaping/non-string values, unreadable configured source,
   empty source, and a non-zero source.
2. Update `agents/design/collectors.sh` and
   `skills/shipyard/inspect.py:_fyi_usage_adapters` to use the same validated
   path contract. Unset must read exactly `data/usage/*.jsonl`; missing/empty
   and configured-unreadable states remain distinguishable.
3. Add the installer-interview question “What is real usage here, and which
   project-relative directory contains its JSONL beacons?” to
   `skills/install/SKILL.md`; document `[design].usage_path` in
   `docs/INSTALL.md` and the README control table.
4. Route the consumer-side Daily Dispatch change through Ice's own ticket/code:
   `scripts/newspaper.py:_usage_assessment` must honor the same optional setting
   and retain `kind=usage`. The existing Bopthere ticket
   `docs/tickets/pending/044_chore_usage_beacon_silence_instrumentation.md`
   remains the project-local path to a real third beacon; instrumentation alone
   does not close T2.

### Verification

```bash
bats tests/design.bats
bats tests/shipyard-inspect.bats
bash -n agents/design/collectors.sh
python3 -m py_compile skills/shipyard/inspect.py
bash install.sh --dry-run --project .
bash scripts/leak-check.sh
git diff --check
```

The Ice consumer change uses its own repo gate:

```bash
cd ~/code/wabbazzar-ice
.venv/bin/python -m pytest -q scripts/tests/test_newspaper.py
.venv/bin/python scripts/newspaper.py --help
git diff --check
```

**Observable DoD:** hermetic fixtures prove unset compatibility and configured
source behavior in collector, inspector, and Dispatch; the interview and docs
name the same key; a configured missing source is explicit coverage, never a
measured zero. The historical T2 result remains 2/3.

**Delegation: subagent — usage contract implementation.** Own only
`agents/design/collectors.sh`, `skills/shipyard/inspect.py`, their focused
tests, and install documentation. Treat the Ice consumer and Bopthere runtime
ticket as external dependencies. Return ≤40 lines: files changed; RED and GREEN
commands with exit codes/counts; exact coverage JSON for default/empty/bad
config; blockers. Converge honestly or report the precise blocker with the
actual evidence — NEVER fake green, weaken a check, or hand-wave "should
work". Run the real command, read the real file, curl the real port, and report
exact output (exit codes, JSONL lines, HTTP codes), not adjectives.

## Phase 3 — Measure prospective outcome chains (5 points)

### Slice

1. Add red-first fixtures in `tests/shipyard-inspect.bats` for a complete and a
   one-link-missing chain for each floor. Preserve existing historical fixtures
   as partial; never retrofit them with invented evidence.
2. Under existing `[telemetry].outcome_lineage=true`, add content-free event
   fields/routes for proposal, incident, human decision, ticket/work, release
   commit, and dispatch usage assessment. Release success records the reviewed
   commit SHA; Git ancestry proves merge/trunk containment read-only.
3. Teach `skills/shipyard/inspect.py:_benchmark_effectiveness` to join exact
   IDs and commits. Complete chains yield `state=measured` and a numeric value;
   complete below-floor evidence is measured failure; an absent required link
   stays partial with its exact missing-link code.
4. Extend decision parsing additively for controlled enums
   `decision_class=consequential`, `decided_by=human`, and boolean
   `default_withheld=true`. Reason prose is ignored. A bare legacy approval
   remains valid operationally but cannot satisfy T4.
5. Update `dashboard/tests/test_operator.py` and the operator fixture for
   measured pass/fail and partial mapping. Keep every `promise:<key>` ID stable.

### Required chain contracts

- **T1:** incident/release finding ID → bug proposal ID → human approval →
  ticket/work IDs → successful release commit → commit contained in trunk.
- **T2:** declared usage source → non-zero valid observation → explicit
  `dispatch.usage.assessed` for the same project/window.
- **T3:** feature proposal ID → human approval timestamp → build/work timestamp
  → successful release commit → commit contained in trunk, in that order.
- **T4:** consequential decision record with human actor and
  `default_withheld=true`; no build inference substitutes for the decision.

### Verification

```bash
bats tests/shipyard-inspect.bats
python3 -m unittest dashboard.tests.test_operator
bash -n agents/lib/outcome-lineage.sh agents/design/runner.sh agents/build/runner.sh agents/release/runner.sh
python3 -m py_compile skills/shipyard/inspect.py dashboard/operator.py
bash .agents/skills/shipyard/shipyard.sh inspect --days 5 --json | jq -e '.effectiveness | length >= 4'
bash scripts/leak-check.sh
git diff --check
```

Where a producer changes, its focused Bats test must also prove
`outcome_lineage=false` and unset emit exactly the legacy bytes. No test may
call GitHub, the network, or a model.

**Observable DoD:** complete fixtures return measured values, incomplete
fixtures name one missing link, a build-before-stamp feature fails ordering,
operator promises become verified/violated only from measured inspector rows,
and a live opt-out inspector run remains content-free and read-only.

**Delegation: subagent — lineage and inspector slice.** Own the schema fixtures,
producer opt-in fields, inspector joins, and operator tests; do not publish or
merge. Return ≤40 lines: files changed; RED/GREEN commands + exit codes/counts;
one complete and one missing-link JSON row per floor; byte-compat proof;
blockers. Converge honestly or report the precise blocker with the actual
evidence — NEVER fake green, weaken a check, or hand-wave "should work". Run
the real command, read the real file, curl the real port, and report exact
output (exit codes, JSONL lines, HTTP codes), not adjectives.

## Phase 4 — Full gate, live proof, and graduation (2 points)

### Slice

1. Re-run the real inspector and operator adapter. Historical evidence remains
   partial/citation-based; a complete prospective fixture or opt-in canary is
   measured without payload leakage.
2. Confirm the Daily Dispatch produces usage assessments from each declared
   source and that the current fleet has three real projects only after the
   third beacon actually emits. If it remains 2/3, record the dependency and do
   not claim that finding closed.
3. Run the complete Shipyard gates, render/inspect both public viewports, verify
   no background browser remains, and confirm skill links do not resolve into a
   worktree.
4. Commit each repository separately. Push Shipyard `main` only after all gates
   pass; do not push Ice's pre-existing local commits without separate owner
   direction. Graduate this ticket only when every roll-up item, including the
   real third project, is evidenced.

### Verification

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py skills/shipyard/inspect.py dashboard/operator.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
bash scripts/ticket-lifecycle.sh --project . --check
git diff --check
ls -l ~/code/*/.claude/skills/ | grep -c worktrees
```

The final link command must print `0`. After push, verify CI and both Pages
copies match the committed deck bytes. No direct notification call is required;
the Daily Dispatch is the promised human surface.

**Observable DoD:** full gates and CI are green, the deck and README show the
same 2/4 historical result, prospective fixtures are measured honestly, three
real usage projects are visible before T2 follow-up closure, Git is clean and
converged, and no browser/worktree residue remains.

**Delegation: inline (final canonical Git, live evidence, and public-publish
boundary must be personally verified by the orchestrator).**

## Roll-up Definition of Done

- [x] Ice's Phase 12 has five dated ledger rows and a sign-off row recording
      T1 PASS, T2 MISS, T3 MISS, T4 PASS without altering the window.
- [x] README and the public presentation state **2/4**, name both misses, and
      link this follow-up; generated presentation data is fresh.
- [x] No late Work Mac commit or synthetic event receives trial credit.
- [x] `[design].usage_path` is documented, validated, honored by collector,
      inspector, and Dispatch, with unset preserving `data/usage` exactly.
- [x] The installer interview asks what real usage means and where its beacons
      live.
- [x] Complete prospective chains produce measured numeric values; incomplete
      chains remain partial with exact missing links; build-before-stamp fails.
- [x] Operator promise IDs are unchanged and map measured pass/fail to
      verified/violated while partial remains unverified.
- [ ] A real third-project non-zero beacon appears in the Daily Dispatch before
      the T2 repair is called closed.
- [ ] Full tests, syntax, leak, lifecycle, deck freshness/completeness/render,
      live inspector, CI, and Pages gates are green.
- [ ] Shipyard is clean and converged on canonical `main`; Ice's unrelated
      local history was neither rewritten nor pushed accidentally.

## Dependencies and boundaries

- **Project-local T2 repair:** Bopthere ticket
  `docs/tickets/pending/044_chore_usage_beacon_silence_instrumentation.md`, or a
  separately routed Starbird project ticket if that becomes the genuine third
  source. Those repos own their own decision tables and gates.
- **Daily Dispatch consumer:** Ice owns `scripts/newspaper.py` and the Phase 12
  ledger. Make its change and commit separately under Ice's gates.
- **Public publishing:** Shipyard `main` deploys GitHub Pages and the configured
  mirror. The owner has authorized the content update; all gates still precede
  push.
- **Out of scope:** extending the historical window, backfilling events,
  counting instrumentation as use, changing promise IDs/schema version,
  raw/private telemetry in tracked files, or rewriting Work Mac/Ice history.

## Traps

- `leak-check.sh` ignores untracked files: use `git add -N` before its first
  run on a new ticket.
- Shipyard is fleet-live and must stay on canonical `main`; do not create a
  branch/worktree or commit a red phase.
- Skill/install commits can relink the fleet; verify zero worktree-resolved
  skill links after every such commit.
- The deck's generated JSON must be regenerated from editorial; never hand-edit
  `docs/shipyard-data.json`.
- A text-only deck check is insufficient: inspect `1440×900` and `390×844`,
  then clean up the browser.
- Ice JSONL has corrupt lines; aggregate with `jq -R 'fromjson?'`.
- Ice is locally ahead of its remote. Scope its commit to the Phase 12 ticket
  and never push inherited commits as an incidental Shipyard action.

## Toolchain proof captured while polishing

On merged Shipyard `ab15f11577b3454823ce0371ece9d8dfe86e20cb` on
2026-08-04:

- `bats tests/shipyard-inspect.bats` — 77/77, exit 0 in 19.28s.
- `python3 -m unittest dashboard.tests.test_operator` — 49/49, exit 0.
- `node scripts/check-deck-render.mjs` — all assertions pass, exit 0.
- `bash scripts/check-deck-fresh.sh` — in sync, exit 0.
- `bash scripts/check-deck-complete.sh` — 8 installed skills complete, exit 0.
- Live five-day inspect — 8 projects; all four historical floors partial;
  usage components 2 projects/1571 records.
- Tools present: Bats 1.10.0, Node 24.12.0, Python 3.12.3, gh 2.83.2.

## Ledger

The builder appends per phase: plan, `builder:` line, commit hash per repository,
RED/GREEN and real-system output, rendered viewport evidence, and honest
deferred dependencies. A phase with an unmet observable DoD is not committed as
complete.

### Phase 1 — Publish the historical finding

- **Plan:** update the Ice owner ledger from immutable event/Git evidence; add
  one aggregate result to the Shipyard README; turn the existing deck table
  into the single result ledger; add source/render guards; regenerate the deck;
  personally run every Phase 1 gate at both declared viewports before separate
  repository commits.
- **builder: subagent (1 agent)** — bounded read-only public-closeout review;
  the orchestrator retains the Ice edit, final copy decisions, rendering, and
  verification because Ice has inherited unpushed commits and the deck publish
  boundary is outward-facing.
- **Starting state:** Shipyard `10b5671` on canonical `main`, clean and one
  commit ahead of `origin/main`; Ice clean on `master`, six inherited commits
  ahead of `origin/master`. Ice push is explicitly excluded.
- **builder result:** the read-only reviewer found no evidence contradiction and
  recommended the exact 2/4 aggregate, three-column result table, completed
  Phase 12 editorial state, and desktop/mobile source and browser guards. Its
  baseline commands were render exit 0, Bats 10/10, and source audit exit 0.
- **Commits:** Ice `dd31f96` updates only the owner ticket; Shipyard `f694f7b`
  publishes the README/deck result and its regression guards. Ice remains local
  and was not pushed with its seven inherited commits.
- **Verification:** generator exit 0; deck-fresh exit 0 after staging the
  regenerated artifact; deck-complete reports 8 skills; browser render exit 0;
  Bats 11/11; leak-check, ticket lifecycle, and both repositories' diff checks
  exit 0. Ice's venv newspaper suite is 44/44 and `newspaper.py --help` exits 0.
- **Rendered proof:** read and presentation modes at `1440×900` and `390×844`
  show headers `Criterion · Floor · Result` and results
  `PASS · MISS · MISS · PASS`; document/table horizontal overflow is 0px and
  console/page errors are empty. Personally inspected table captures are
  836×279 desktop and 350×584 mobile; all copy is readable without clipping.
- **Outcome:** Phase 1 DoD met. The historical closeout is intentionally 2/4;
  post-window WorkMac/PR #17 activity was not credited. Public deployment waits
  for the normal Shipyard push boundary; the follow-up remains pending while
  Phases 2–4 are built.

### Phase 2 — Declare real-usage sources and close the routing gap

- **Plan:** establish one optional project-relative `[design].usage_path`
  contract with `data/usage` as the byte-compatible unset default; prove bad,
  missing, empty, and non-zero sources independently; apply it to the collector,
  inspector, installer interview/docs, and Ice's `kind=usage` Dispatch consumer;
  keep the real third-project beacon as an honest external dependency.
- **builder: subagent (1 agent)** — owns the Shipyard collector/inspector,
  focused Bats fixtures, installer interview, and install/public documentation.
  The orchestrator owns the separate Ice consumer/tests and personally runs all
  cross-repository gates before commits.
- **Starting state:** Shipyard `63b19b8`, clean and three commits ahead of
  `origin/main`; Ice `dd31f96`, clean and seven inherited commits ahead of
  `origin/master`. Neither repository is pushed mid-phase.
- **RED:** pre-change `tests/design.bats` failed 4/15 and the four focused
  inspector usage cases failed 4/4. Ice's focused consumer run failed 6 of 7
  original cases against the fixed `data/usage` implementation; the one unset
  default case passed and pinned compatibility.
- **Commits:** Shipyard `409c13c` implements and documents the shared source
  contract; Ice `cb0d2c3` applies it to the Dispatch consumer. Ice remains
  local and its eight inherited commits were not pushed.
- **GREEN:** design Bats 15/15; inspector Bats 80/80; collector shell syntax,
  inspector byte-compile, leak-check, and diff check all exit 0; installer
  dry-run ends `install: OK`. Ice's newspaper suite is 53/53, byte-compile and
  `--help` exit 0, and its diff check is clean.
- **Coverage proof:** the unset source resolves only `data/usage`; a valid
  configured source reports `available/ok` with non-zero evidence. Missing,
  empty, and unreadable report `unavailable/missing`, `available/empty`, and
  `unavailable/unreadable`; invalid absolute, escaping, and non-string values
  report `error/invalid_config`. The collector preserves zero counters for every
  non-measured state; the inspector emits no usage evidence for those states.
- **Consumer proof:** the Dispatch retains `kind=usage` for an explicitly
  unavailable configured source without exposing its path. Unavailable rows
  are never counted by the historical trial-watch tally; a valid alternate
  directory produces the same top-action summary as the unset default.
- **Outcome:** Phase 2 DoD met, but T2 remains honestly **2/3**. Configuration
  and coverage semantics are repaired; a real third beacon is still blocked on
  Bopthere ticket `044_chore_usage_beacon_silence_instrumentation.md` and no
  instrumentation-only credit was taken.

### Phase 3 — Measure prospective outcome chains

- **Plan:** add prospective, content-free lineage under the existing opt-in;
  prove exact T1–T4 joins, ordering, trunk containment, controlled decision
  enums, and one-link-missing diagnostics; keep all historical component-only
  fixtures partial; map only measured inspector rows to verified/violated
  operator promises; prove false/unset producer bytes are unchanged.
- **builder: subagent (1 agent)** — owns Phase 3 producer fields/routes,
  inspector fixtures and joins, operator adapter/tests, and focused gates. The
  orchestrator retains privacy/schema review, live opt-out inspection, final
  gate execution, and canonical commits.
- **Starting state:** Shipyard `f1068b8`, clean and five commits ahead of
  `origin/main`; Ice `cb0d2c3`, clean and eight inherited commits ahead of
  `origin/master`. Ice changes remain a separate local commit and are never
  pushed through Shipyard's publication boundary.
- **RED:** five complete/missing-link inspector fixtures failed 5/5 before the
  joins existed; the ticket producer lineage case failed 1/1 before the build
  runner carried opaque work and upstream IDs.
- **Commits:** Shipyard `d6afc14` implements the inspector joins, bounded
  read-only Git-containment proof, build lineage, stable operator mapping, and
  regression fixtures. Ice `1b13da7` adds the opt-in Dispatch usage-assessment
  and controlled human-decision producers. Ice is nine inherited/local commits
  ahead of `origin/master` and was not pushed.
- **GREEN:** inspector Bats 89/89, operator unit tests 49/49, and incident/build
  Bats 10/10; shell syntax, Python byte-compile, leak-check, and diff checks all
  exit 0. Ice's newspaper suite is 56/56, focused action suite 25/25, full
  dashboard suite 205/205, Svelte check has 0 errors (one pre-existing layout
  warning), production build succeeds, and its diff check is clean.
- **Lineage proof:** T1 and T3 require temporal order plus a successful release
  commit that actually contains the built commit on trunk; the Git query is
  cached, read-only, bounded to two seconds, and fails closed. T2 requires one
  stable assessment ID for the same project, declared source ID, and window,
  rejects backfills, and deduplicates repeats. T4 requires the controlled
  consequential/human/default-withheld triple; a bare approval and dry-run do
  not receive credit. False/unset producers preserve legacy bytes, and opt-in
  records contain IDs, enums, counts, timestamps, and Git objects only.
- **Live proof:** the read-only five-day inspector exits 0 and leaves all four
  current historical promises `partial`, with exact reasons
  `missing_bug_fix_lineage`, `missing_usage_assessment_lineage`,
  `missing_feature_delivery_lineage`, and
  `missing_decision_consequence_judgment`; no historical evidence was
  upgraded. The locally deployed Ice dashboard is `active`; `/operations` and
  `/news` return 200. A `390x844` `/news` render has no console/page errors or
  horizontal overflow and the browser process exited cleanly.
- **Outcome:** Phase 3 DoD met prospectively. Complete fixtures measure honest
  pass/fail values, incomplete chains remain partial, and operator promises use
  unchanged IDs. The original trial remains **2/4**, and the real third-project
  usage dependency remains open for Phase 4.

### Phase 4 — Full gate, live proof, and graduation

- **Plan:** run the entire canonical suite and every declared release gate;
  exercise the live inspector and loopback operator adapter; build a read-only
  Daily Dispatch edition to count declared non-zero usage sources; verify the
  deployed Ice PWA, deck viewports, browser cleanup, and fleet skill links;
  publish Shipyard and its configured deck mirror only from a clean committed
  main; leave the ticket pending unless a genuine third usage project appears.
- **builder: inline (operating constraint)** — the phase owns final canonical
  Git, live services, and outward publication, which the ticket reserves for
  the orchestrator; no implementation slice remains to delegate.
- **Starting state:** Shipyard `dd16a95`, clean and seven commits ahead of
  `origin/main`; Ice `1b13da7`, clean and nine inherited/local commits ahead of
  `origin/master`. Ice remains explicitly excluded from push.
- **Local release gate:** canonical Bats passes 793/793. The full shell syntax
  sweep, Python byte-compile, leak firewall, deck freshness, deck completeness
  (8 skills), browser render, lifecycle, and diff checks exit 0. The literal
  worktree-link probe prints `0`; an explicit zero-count assertion exits 0.
- **Live inspector/operator proof:** the five-day inspector exits 0 with
  `usage_projects_observed=2`, `usage_records=1571`, and all four trial promises
  partial for their exact lineage reasons. The real loopback operator endpoint
  returns HTTP 200, schema 1, `kind=shipyard.operator`, a fresh
  `shipyard-inspect-v1` snapshot, stable promise IDs, and all four rows
  `unverified/evidence_incomplete` rather than green.
- **Dispatch proof:** `.venv/bin/python scripts/newspaper.py --no-prose
  --stdout` is read-only and produces exactly two `kind=usage` rows: Aurora and
  Shredly. No Bopthere or Starbird non-zero assessment exists, so T2 remains
  **2/3** and no lineage event or historical credit was fabricated.
- **Deployed Ice proof:** the dashboard service is active; `/operations` and
  `/news` return 200; the production build and complete test surfaces are green.
  A `390x844` `/news` render has zero horizontal overflow and no console/page
  errors, and no browser process remains.
- **Outcome:** Phase 4 is intentionally **not complete**. The code, local
  release gates, and live read-only proofs are green, but graduation remains
  blocked on a real third-project non-zero beacon followed by its Dispatch
  assessment. Publication, remote CI, Pages equality, and canonical convergence
  are recorded after the Shipyard push; the ticket stays in `pending`.

---

Run with `execute-ticket docs/tickets/pending/close-five-day-trial-findings.md`.
