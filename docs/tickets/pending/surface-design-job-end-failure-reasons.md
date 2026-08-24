# Surface `job.end` failure reasons in design telemetry examples

- **Created:** 2026-08-24
- **Owner:** wabbazzar
- **Status:** Pending — polished; no open decisions
- **Priority:** low
- **Type:** bugfix
- **Estimated Points:** 2 (two phases: 1 · 1)
- **Refs:** approved Daily Dispatch item `mentat:shipyard:411240ae`;
  `agents/design/collectors.sh:251-287`, `agents/design/runner.sh:284-290`,
  `agents/design/runner.sh:352-359`, `tests/design.bats:49-70`,
  `tests/design.bats:103-133`

## Goal

Preserve the optional `reason` already carried by source telemetry when the
design collector projects recent events into
`.sources.events.examples`. A `job.end` failure such as
`reason:"claude_failed"` must reach Mentat's compact telemetry context, while
reason-less examples remain explicit as `reason:null`.

## Captured defect and root cause

The configured live event stream contains this terminal event at
`$QUARTET_EVENTS_DIR/2026-08-20.jsonl:16623`:

```json
{"ts":"2026-08-20T10:00:03Z","svc":"shipyard-mentat","event":"job.end","source":"system","role":"design","mode":"design","status":"fail","duration_s":2,"reason":"claude_failed"}
```

On 2026-08-24 CDT, resolving `QUARTET_EVENTS_DIR` from
`shipyard-mentat.service` and running the real read-only collector reported
`job_fail:1` and retained that Aug 20 event among its five examples, but emitted
only `ts`, `svc`, `event`, and `status`. This assertion returned `false` and
exit 1:

```bash
events_dir="$(systemctl --user show shipyard-mentat.service \
  -p Environment --value | tr ' ' '\n' | \
  sed -n 's/^QUARTET_EVENTS_DIR=//p')"
summary="$(QUARTET_DIR="$PWD" QUARTET_EVENTS_DIR="$events_dir" \
  bash agents/design/collectors.sh --project . --json)"
jq -e 'any(.sources.events.examples[];
  .svc=="shipyard-mentat" and .status=="fail" and
  .reason=="claude_failed")' <<<"$summary"
```

The producer is already correct: `agents/design/runner.sh:284-290` forwards
extra key/value fields to `job.end`, and its failure path calls
`finish fail reason=claude_failed` at `:352-359`. The loss occurs only in
`agents/design/collectors.sh:285-286`, whose examples projection is currently
`{ts, svc, event, status: (.status // null)}`.

The coverage gap is equally narrow. `tests/design.bats:49-70` plants event
telemetry and `:107-133` verifies counts, source immutability, FYI, and usage,
but no test plants a `reason` and inspects the examples projection. The approved
proposal names `tests/design-collectors*.bats`; no file matches that path on
current `main`. Canonical collector coverage is `tests/design.bats`, so the
regression belongs there rather than in a parallel test file.

## Decisions

### Locked decisions

| Decision | Locked result |
|---|---|
| Projection | Add exactly `reason: (.reason // null)` beside `status` in the existing `examples` object projection. |
| Value semantics | Preserve an existing JSON `reason` value verbatim. Do not infer, translate, classify, truncate, or synthesize a reason. Missing/null remains explicit JSON null. |
| Selector and bounds | Preserve the existing `job.end|medic.|release.critique` selector, timestamp sort, reverse ordering, and five-example cap byte-for-byte except for the new field. |
| Test location | Extend existing `tests/design.bats`; do not create a stale-path `tests/design-collectors*.bats` sibling. |
| RED construction | Add an isolated collector fixture with a recent failed `job.end` carrying `reason:"claude_failed"` and a reason-less example. Against pre-change collector code, require the failed example's exact reason and require both objects to have a `reason` key; failure must be attributable to the dropped field, not the newest-five cap. |
| Compatibility | Existing reason-less examples acquire only `reason:null`; all event counts, other example fields, malformed-line tolerance, source immutability, and human rendering remain unchanged. |
| Configuration | No config key. This is a nullable field correction inside an existing read-only collector projection, not a runner/installer capability; `.agents/gates.md` limits config-gated additivity to runner/installer changes. |
| Publication | Work in the canonical checkout on local `main`; publish the final exact head to a remote PR branch without switching locally. `can_merge=false`: require green CI and stop for human merge. |

### Open decisions with defaults

None.

### User-decision class

None. Daily Dispatch already approved the exact projection, fixture, and scope.
This change does not spend money, expose a surface, delete state, or alter a
deliberately configured live-automation decision.

**Auto-gate: PROCEED.**

## Boundaries

### Always

- Keep `agents/design/collectors.sh` read-only and corrupt-line tolerant.
- Make the regression fail against the actual pre-change projection before
  editing it.
- Preserve raw event values and the existing compact five-example envelope.

### Ask first

- Adding any event field beyond `reason` to the compact examples.
- Changing the event selector, ordering, or five-example cap.

### Never

- Change what reasons any runner emits.
- Edit `agents/design/runner.sh`, another runner, `agents/lib/post-run.sh`, or
  event-writing helpers.
- Change medic classification/escalation or the caddy, FYI, usage, or incident-
  file collectors.
- Start `shipyard-mentat.service` as proof: that invokes a real model and may
  draft proposals. The collector has a direct read-only CLI and hermetic tests.

## Orchestration protocol

The builder is the orchestrator. Delegate implementation by default, keep
returns bounded, and personally rerun every named gate before every commit.
Work only in this canonical checkout on local `main`; do not create or switch a
local branch/worktree. Before each edit and commit, run
`git status --short --branch` and `git log --oneline -3`. If another session
changes the head or overlaps these files, stop staging and reconcile without
reset, rebase, force-push, or lost history. Scope `git add` to this ticket's
files; never use `git add -A`.

`agents/design/collectors.sh` is fleet-live because every installed design
runner invokes it from this checkout on its next timer. Do not leave the
focused collector surface red between commits and do not trigger a billable
Mentat run.

For every delegated slice:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

No installed specialist manifests exist under `.agents/specialists/`, so the
generic delegation flow applies and no specialist verdict is required.

## Verified polishing baseline — 2026-08-24 CDT

| Surface | Evidence | Consequence |
|---|---|---|
| Git | Clean canonical `main` equals `origin/main` at `b1a6631`; no matching ticket or commit exists. | Create the ticket in `docs/tickets/pending`, commit on local `main`, and preserve concurrent history. |
| Approval | `tmp/shipyard-mentat-result.json:118-126` contains the proposal; `data/decisions.jsonl:12` contains its single approval at `2026-08-24T12:13:40.671Z`. | No additional product stamp is needed. |
| Live defect | The configured Aug 20 source event has `reason:"claude_failed"`; the real seven-day collector output has `job_fail:1` and the same failure example without `reason`. The exact assertion above exits 1. | Acceptance must inspect the projected example, not merely the source event or count. |
| Producer boundary | `agents/design/runner.sh:284-290,352-359` already emits the field; `skills/shipyard/inspect.py:1593-1610,1922-1931` separately demonstrates preserving and aggregating `job.end.reason`. | Do not touch producers or copy inspector logic; repair one projection. |
| Existing coverage | `bats --count tests/design.bats` → 15; focused collector test passed 1/1; `bats tests/design.bats` passed 15/15. | Add one focused test to the canonical file and preserve all 15 guards. |
| Full toolchain | Bats 1.10.0; `bats tests/` passed 818/818. Full shell syntax and Python compile passed; leak, deck freshness/completeness, lifecycle, and diff checks passed. Main CI run `32416355575` is green at `b1a6631`. | The ticket's exact commands exist locally; any new regression belongs to this delivery unless independently evidenced. |
| Live scheduling | `shipyard-mentat.timer` is enabled for the next configured daily run; units point at this canonical checkout. | Keep commits green; use the direct collector CLI, never a manual service start. |
| Capability | `.agents/config.toml` keeps `allow_no_ci=false` and `can_merge=false`. | A green PR is mandatory; the builder may not merge it. |

## Phase 1 — preserve failure reasons at the collector boundary (1 point)

Add one narrowly named test inside `tests/design.bats`. Give its private event
fixture two recent `job.end` records for the fixture project: one failed record
with `reason:"claude_failed"`, and one reason-less record. Run the new test
against unchanged `agents/design/collectors.sh` and record the RED showing the
source reason exists but the projected object lacks the key. The fixture must
contain fewer than five selected examples so the cap cannot cause the RED.

Then add only `reason: (.reason // null)` to the projection at
`agents/design/collectors.sh:285-286`. GREEN must prove:

- the failed example has the exact original string;
- both projected objects contain the `reason` key;
- the reason-less example is JSON null;
- the collector writes no source/project files; and
- the existing 15 collector/design tests remain green.

**Files:** `agents/design/collectors.sh`, `tests/design.bats`, this ticket.

**Delegation:** subagent — starting from this polished ticket and its committed
baseline, own only `agents/design/collectors.sh` and `tests/design.bats`. Add the
isolated fixture/test first and run it against unchanged collector code to
record the exact RED. Then make the one-field projection edit and run focused
GREEN plus the complete design suite. Do not edit the ticket, runner/producers,
medic, other collector sections, docs, config, units, or remote state; do not
invoke a model, systemd service, notification, GitHub, or the git index. Return
≤40 lines: files changed; RED/GREEN commands with exit codes/counts; exact
source and projected JSON assertions; source checksum/read-only evidence;
scope check; blockers. Apply the anti-cheating clause in the Orchestration
protocol verbatim.

**Phase 1 verification surface:**

```bash
git status --short --branch
git log --oneline -3
bash -n agents/design/collectors.sh
bats --filter 'collectors preserve job.end failure reason in examples' tests/design.bats
bats tests/design.bats
bash scripts/leak-check.sh
git diff --check
python3 scripts/delegation-report.py
git diff --name-only -- agents/design/runner.sh agents/lib/post-run.sh agents/medic agents/design/collectors.sh tests/design.bats
```

Observable Phase 1 DoD: the Ledger contains the real RED and GREEN; focused
output passes 1/1 and design output passes 16/16; the projected failed example
contains the exact reason, the reason-less example contains an explicit null,
fixture input checksums are unchanged, and the only product/test diffs are the
single projection field and its regression.

## Phase 2 — complete gates, lifecycle, and PR handoff (1 point)

From a clean Phase 1 commit, rerun the entire repository gate matrix. Inspect
the Phase 1 commit/diff once more to prove producer, medic, and other collector
sections are untouched. Graduate this ticket deterministically only after all
behavioral gates pass, commit the lifecycle move, and publish the exact head to
a PR with green required CI. Do not merge.

**Delegation:** inline (the orchestrator must personally read the full gate,
lifecycle, publication, CI, and owner-alert results). This is limited to gate
commands and final ticket/PR state; implementation remains delegated.

**Phase 2 verification surface:**

```bash
git status --short --branch
git log --oneline -3
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bats tests/
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs  # exit 0, or documented exit 3 only when Playwright is absent
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py
git diff --check
git diff origin/main...HEAD -- agents/design/runner.sh agents/lib/post-run.sh agents/medic
find ../* -path '*/.claude/skills/*' -type l -lname '*worktrees*' -print 2>/dev/null | wc -l  # must print 0
```

After those pass:

```bash
bash scripts/ticket-lifecycle.sh --project . --graduate \
  docs/tickets/pending/surface-design-job-end-failure-reasons.md
git fetch origin main
git status --short --branch
git log --oneline origin/main..HEAD
git push origin HEAD:refs/heads/bugfix/design-collector-failure-reason
gh pr create --repo wabbazzar/shipyard --base main \
  --head bugfix/design-collector-failure-reason \
  --title "Surface job.end failure reasons in design telemetry" \
  --body-file <prepared-body>
gh pr checks <number> --repo wabbazzar/shipyard --watch --interval 10
```

Require the PR head SHA to equal local `HEAD` and all six required checks—git
identity, leak, shell, deck freshness, ticket lifecycle, and Bats—to conclude
success. Send exactly one PR-ready alert through the configured
`$QUARTET_NOTIFY_CMD`, record its exit, and stop for the human merge stamp. If
GitHub or notification transport is unavailable, record the exact external
state; never treat missing CI as green and never self-merge.

Observable Phase 2 DoD: full Bats passes 819-or-later; all canonical local and
CI gates are green; the worktree is clean; the exact verified head is on the PR;
the ticket is in the configured archive directory; no local branch/worktree or
worktree-linked skill symlink exists; and GitHub still shows the PR unmerged.

## Definition of Done

- [x] A failing-first hermetic test proves a source `job.end` reason is dropped by the pre-change examples projection.
- [x] A failed `job.end` example preserves `reason:"claude_failed"` exactly.
- [x] Every projected example has a `reason` key; absent/null source reasons become JSON null.
- [x] Existing selector, newest-five ordering/cap, counts, malformed-line tolerance, source immutability, and human output are unchanged.
- [x] No runner reason emission, post-run event logic, medic behavior, or caddy/FYI/usage/incident-file collector changes.
- [x] Focused collector coverage passes 1/1 and `tests/design.bats` passes 16/16.
- [ ] Full Bats, syntax, Python compile, leak, deck freshness/completeness/render, lifecycle, delegation, diff, and worktree-link gates pass.
- [ ] The ticket is graduated in the final commit and the exact head is published through a green PR without self-merge.

## Ledger

- 2026-08-24 — polishing discovery: `builder: subagent (1 agent)` performed a
  bounded read-only history/coverage sweep; `builder: inline (gate commands and
  live collector evidence the orchestrator must read itself)` verified the
  current repo, installed config/gates, live source event, dropped live
  projection, producer boundary, current tests/toolchain, timer, capabilities,
  recent ticket convention, absent specialists, and green main CI. The approved
  scope has no open decision. No product code, config, service, model,
  notification, or remote state changed during polish.
- 2026-08-24 — Phase 1 plan: `builder: subagent (1 agent)` owns only the
  collector projection and canonical design test. It must capture the isolated
  failing-first assertion before the one-field edit, preserve the fixture
  checksum/read-only contract, and return bounded evidence. Root retains all
  independent gates, Ledger edits, staging, and commit authority. Phase 2 is
  `builder: inline (gate, lifecycle, publication, CI, and owner-alert commands
  the orchestrator must read itself)`.
- 2026-08-24 — Phase 1 RED/GREEN: the delegated builder added the isolated
  two-event fixture while `agents/design/collectors.sh` still matched committed
  SHA-256 `0e36d14f...f6de48`. The focused test failed 0/1: its source retained
  `reason:"claude_failed"`, while both projected examples omitted `reason`;
  source checksum `6c677610...c8280b` and the fixture project's clean status
  were unchanged. Adding only `reason: (.reason // null)` made focused coverage
  pass 1/1 and `tests/design.bats` pass 16/16; the failed example retained
  `claude_failed`, the reason-less example became `null`, and both acquired the
  key. `builder: inline (independent gate commands)` reran shell syntax, focused
  and complete design Bats, leak, diff, delegation, and forbidden-file checks
  successfully. The direct read-only live collector also now exposes the Aug 20
  `claude_failed` event among its five examples without starting Mentat.

---

Run `execute-ticket` on this decision-complete ticket.
