# Shipyard inspect human output is not operator-readable

- **Created:** 2026-07-30
- **Owner:** wabbazzar
- **Status:** Ready
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 5 (Phase 1: 3; Phase 2: 2)
- **Refs:** `skills/shipyard/inspect.py`, `tests/shipyard-inspect.bats`,
  `docs/tickets/complete/shipyard-fleet-inspect-cli.md`

## Goal

Restore the documented `shipyard inspect` contract: the default rendering is a
concise, scannable operator report, while `shipyard inspect --json` remains the
complete schema-v1 evidence document for Claude, Codex, Hermes, and automation.

The human view must answer, at a glance:

1. what is the fleet's current observed state;
2. what needs the human operator's attention;
3. what Shipyard effectiveness is and is not measurable;
4. where the next Shipyard PR should focus; and
5. which important evidence sources are incomplete.

## Captured Reproduction

Run from the Shipyard repository:

```bash
bash skills/shipyard/shipyard.sh inspect > /tmp/shipyard-human.txt
wc -l -c /tmp/shipyard-human.txt
awk 'length > max { max=length } END { print max }' /tmp/shipyard-human.txt
```

Captured on 2026-07-30 against the installed current-user fleet:

```text
250 28622 /tmp/shipyard-human.txt
447
```

The report contained eight dense fleet rows, 138 attention rows, eight
effectiveness rows, 36 lines for 18 priorities, and 46 coverage rows. Standard
error was empty. Re-running the command directly and through the installed
`shipyard` alias produced byte-identical output, so the alias and shell startup
path are not the cause.

### Violated observable contract

The completed fleet-inspect specification says the default is a **concise
operator report** and `--json` is the stable source document. A 250-line,
28-KiB default report with 447-character rows cannot be scanned as an operator
console and merely duplicates the exhaustive JSON surface in a harder-to-parse
form.

## Root Cause

- **Where:** `render_human()` in `skills/shipyard/inspect.py` iterates every
  fleet, attention, effectiveness, priority, and non-available coverage record;
  fleet rows also expand every role, budget consumer, pressure operand, and
  safety field onto one line.
- **When:** commit `3e54321` (`feat: rank fleet priorities and render operator
  view`, 2026-07-29) introduced the exhaustive loops and dense fleet rendering.
- **Elsewhere:** the same output-growth class is present across the one human
  renderer's five sections; there is no competing renderer or alias fork.
  Schema-v1 JSON is intentionally exhaustive and is not defective.
- **Why tests missed it:** `tests/shipyard-inspect.bats` asserted that every
  JSON attention and priority ID appeared in human output and checked field
  presence, but imposed no row, width, omission-summary, or scanability bound.
  The regression suite therefore protected the wrong exhaustive-human
  contract.

## Locked Behavior

### One document, two intentional levels of detail

- `inspect --json` remains byte-for-schema compatible: schema version, fields,
  values, array contents, and array ordering do not change.
- Default human output is a bounded digest of that same in-memory document.
- The existing section names remain, in this order: `FLEET`, `ATTENTION`,
  `EFFECTIVENESS`, `NEXT SHIPYARD PR`, `COVERAGE`.
- No `--verbose` mode or second data path is introduced. Every omitted human
  detail remains available through `--json`.

### Human rendering limits

The renderer uses these fixed caps:

| Section | Aggregate | Detailed rows |
|---|---|---|
| `FLEET` | project and state counts | first 10 projects in document order |
| `ATTENTION` | counts by attention kind | first 5 items in document order |
| `EFFECTIVENESS` | counts by effectiveness state | all current fixed benchmark rows, capped at 8 |
| `NEXT SHIPYARD PR` | total candidate count | first 5 priorities in existing ranked order |
| `COVERAGE` | counts by coverage state | first 5 actionable gaps in document order |

For this renderer, an actionable coverage gap has state `partial`, `unavailable`,
or `error`. `not_applicable` contributes to the aggregate state counts but does
not consume a detailed-row slot.

If a section has more displayable records than its cap, it ends with exactly
one omission row of the form:

```text
  … N more; use --json for full evidence
```

Empty sections continue to render `  none`. Every displayed attention and
priority row includes its stable ID. Human selection does not re-rank or mutate
the source arrays.

Aggregate rows use these exact forms and always include zero-valued members in
the order shown:

```text
  counts: fault_observed=N degraded_observed=N no_fault_observed=N unknown=N
  counts: open_proposal=N owner_decision=N observed_fault=N install_drift=N coverage_gap=N
  counts: measured=N partial=N unmeasured=N
  candidates: N
  counts: available=N partial=N unavailable=N error=N not_applicable=N
```

The rows correspond to `FLEET`, `ATTENTION`, `EFFECTIVENESS`,
`NEXT SHIPYARD PR`, and `COVERAGE`, respectively.

### Scanability

- Every rendered line is at most 120 Unicode code points, including indentation
  and the omission row.
- Free-text labels and limitation/reason text may be deterministically clipped
  with a trailing Unicode ellipsis to meet the width bound.
- Stable attention/priority IDs, section names, aggregate counts, states, and
  the `--json` escape hatch must not be clipped.
- Each displayed fleet project uses exactly two indented lines. The first is
  `[<project-id>] <project-name> state=<state> roles=<N> doctor=<state>`. The
  second starts `pressure:` and retains compact budget/open-pressure counts
  followed by configured safety posture in the exact order
  `gates=merge:<value>,no-ci:<value>,verify:<value>,branch:<value>`.
  `budget=max:<percent>` is the largest numeric
  `gate_fraction_today` among applicable consumers, formatted as a whole
  percent (`unavailable` when none is numeric); `deferred=<N>` sums
  `budget_deferrals_by_consumer`; `open=<undecided>/<configured>` and its
  deferral count use the existing open-cap fields. They no longer enumerate
  role names, every budget operand, or every limitation.
- Priority detail is one line per candidate and retains rank, stable ID,
  category, scope, title, and evidence count.
- Coverage detail retains owner, source, state, reason, and valid/total counts.
- The complete report is at most 80 lines for any valid schema-v1 document.

## Decisions

### Locked decisions

| # | Decision | Rationale |
|---|---|---|
| L1 | Fix the existing default renderer; do not add a config key. | The default already promises a concise operator report, and config-gated additivity applies to runner/installer capabilities rather than correction of this read-only CLI regression. The owner already answered “no config.” |
| L2 | Keep schema-v1 JSON exhaustive and unchanged. | JSON is the agent/automation evidence surface and the source for the digest. |
| L3 | Use the fixed caps, order, actionable coverage states, clipping rules, and omission wording above. | A cold builder must not invent a different presentation contract. |
| L4 | Select existing array prefixes; do not add a second ranking rule for human output. | Priority ordering is already evidence-backed and changing attention ranking would expand this bugfix into product semantics. |
| L5 | No alias, installer, systemd, model, event, deck, or live-service change. | Reproduction proves the defect is isolated to `render_human()`. |
| L6 | Work and commit from the canonical checkout on `main`; after all gates pass, push `main` and verify CI/publication status. | The owner explicitly authorized “push” for this CLI work. This resolves the outward-facing decision in advance. |

### Open decisions

None.

### User-decision class

None. L6 records the owner's existing push authorization.

**Auto-gate: PROCEED.**

## Polishing Baseline

Verified on 2026-07-30 from the canonical checkout:

```text
$ bats --version
Bats 1.10.0

$ bats --filter 'inspect: (human|empty and unavailable|JSON stdout)' tests/shipyard-inspect.bats
1..4
ok 1 inspect: human attention and priority ids map exactly to JSON
ok 2 inspect: human fleet lines expose pressure and configured safety posture
ok 3 inspect: empty and unavailable sections render explicitly
ok 4 inspect: JSON stdout contains JSON only and diagnostics use stderr

$ python3 -m py_compile skills/shipyard/inspect.py
exit 0

$ bash scripts/leak-check.sh
leak-check: clean
```

The leak check was run only after
`git add -N docs/tickets/pending/shipyard-inspect-human-output-readability.md`,
so it inspected this new ticket. GitHub CLI 2.83.2 is installed and authenticated
for the configured `origin`.

## Implementation Plan

### Phase 1 — Bound and simplify the human renderer

**Delegation: subagent — renderer and contract-test owner.** Work only in
`skills/shipyard/inspect.py` and `tests/shipyard-inspect.bats`; touch README or
skill prose only if the existing wording contradicts the locked contract.
First add the named failing regression and show it fails against pre-change
`render_human()`. Then implement the exact caps, aggregates, compact fields,
clipping, and omission wording in this ticket without changing document
construction or JSON serialization. Return in at most 40 lines: files changed;
commands run with exit codes; the pre-change failing-test line; post-change test
counts; measured live report lines/maximum width; blockers. Converge honestly
or report the precise blocker with the actual evidence — NEVER fake green,
weaken a check, or hand-wave "should work". Run the real command, read the real
file, curl the real port, and report exact output (exit codes, JSONL lines, HTTP
codes), not adjectives.

- Refactor only `render_human()` and small private presentation helpers in
  `skills/shipyard/inspect.py`.
- Add aggregate count rows, the fixed section caps, compact one-line details,
  deterministic clipping, and explicit omission summaries.
- Replace the exhaustive-ID regression with assertions that displayed IDs are
  valid source IDs, ranked priority selection is preserved, omissions are
  counted correctly, non-actionable coverage does not consume gap slots, and
  the global line/width bounds hold on an intentionally oversized fixture.
- Preserve tests for empty/unavailable sections, JSON-only stdout, diagnostic
  stderr, and configured safety posture in compact form.
- Update the current operator-facing skill/readme wording only if needed to
  make the bounded-human/full-JSON split explicit; do not edit the completed
  historical ticket.

#### Verification surface

The builder must add the Bats case named exactly `inspect: human output is
bounded and summarized`. It replaces the exhaustive human-ID test, updates the
fleet guard to require `roles=2` and reject a parenthesized role-name list, and
updates the empty/unavailable guard to assert the coverage aggregate plus an
omission row rather than assume `delegation_claude` occupies a detail slot.
Before editing `render_human()`, run the new case and record its nonzero exit
against the captured defect:

```bash
bats --filter 'inspect: human output is bounded and summarized' \
  tests/shipyard-inspect.bats
```

The case must exercise an oversized deterministic schema-v1 document and prove:
all five headings and aggregate rows; caps `10/5/8/5/5`; exact omission counts;
priority IDs equal the JSON priority prefix; every displayed attention/priority
ID belongs to its source array; `not_applicable` coverage is aggregated but not
detailed; output is at most 80 lines and every line is at most 120 code points.
It must also feed overlong project/title/reason text so the width assertion can
fail independently of the row-count assertion. Serialize the fixture document
deterministically immediately before and after `render_human(document)` and
assert equality, proving the human renderer does not mutate the JSON source.

After implementation, run the focused contract:

```bash
python3 -m py_compile skills/shipyard/inspect.py
bats --filter \
  'inspect: (human output is bounded and summarized|human fleet lines expose pressure and configured safety posture|empty and unavailable sections render explicitly|JSON stdout contains JSON only and diagnostics use stderr)' \
  tests/shipyard-inspect.bats
```

Then exercise the installed fleet renderer for real:

```bash
python3 - <<'PY'
import json
import subprocess

base = ["bash", "skills/shipyard/shipyard.sh", "inspect"]
human = subprocess.run(base, capture_output=True, text=True, check=False)
assert human.returncode == 0, human.stderr
assert human.stderr == ""
lines = human.stdout.splitlines()
assert len(lines) <= 80
assert max(map(len, lines), default=0) <= 120
machine = subprocess.run(base + ["--json"], capture_output=True, text=True, check=False)
assert machine.returncode == 0, machine.stderr
assert machine.stderr == ""
document = json.loads(machine.stdout)
assert document["schema_version"] == 1
print(
    f"lines={len(lines)} max_width={max(map(len, lines), default=0)} "
    f"projects={len(document['fleet'])} attention={len(document['attention'])} "
    f"priorities={len(document['priorities'])}"
)
PY
```

Run the complete applicable repository gates before commit:

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py skills/shipyard/inspect.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
git diff --check
```

Config-gated additivity, model caps, systemd, served-app, event/notification,
and deck-coupling gates do not apply: this phase changes no runner/installer,
model call, unit, event, notification, served surface, skill frontmatter, or
installed-skill list. Public-repo hygiene and delegation always apply. Commit
the implementation and tests as one phase commit. The skills-worktree trap does
apply even though this is the canonical checkout: after the commit, run:

```bash
test "$(ls -l ~/code/*/.claude/skills/ 2>/dev/null |
  grep -c worktrees || true)" -eq 0
```

#### Observable Definition of Done

- The new focused Bats case fails before the renderer edit and passes afterward.
- The focused contract passes all renderer guards.
- The real default command prints at most 80 lines with maximum width at most
  120, and its JSON sibling still parses as schema version 1.
- `bats tests/` and every applicable static/public-hygiene gate exit 0.
- One clean implementation commit is present on `main`, and the canonical fleet
  skill links do not point into a worktree.

### Phase 2 — Graduate, publish, and observe the result

**Delegation: inline (the orchestrator must personally read the final gates,
lifecycle move, remote ref, and CI result).** Update the ticket Status to
`Complete — built and verified 2026-07-30 UTC`, replace this empty Ledger with
the two phase records and exact evidence, and graduate it:

```bash
bash scripts/ticket-lifecycle.sh --project . --graduate \
  docs/tickets/pending/shipyard-inspect-human-output-readability.md
bash scripts/ticket-lifecycle.sh --project . --check
test -f docs/tickets/complete/shipyard-inspect-human-output-readability.md
test ! -e docs/tickets/pending/shipyard-inspect-human-output-readability.md
git diff --check
```

Commit the status/Ledger/graduation as the second and final local commit.
Re-run `bash scripts/leak-check.sh` and `git status --short`; the latter must be
empty.

Push and verify the exact remote ref:

```bash
git push origin main
test "$(git rev-parse HEAD)" = \
  "$(git ls-remote origin refs/heads/main | cut -f1)"
```

Wait for the workflow attached to that exact commit rather than merely listing
it:

```bash
shipyard_run_id=""
for attempt in 1 2 3 4 5 6; do
  shipyard_run_id="$(
    gh run list --commit "$(git rev-parse HEAD)" --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty'
  )"
  [ -n "$shipyard_run_id" ] && break
  sleep 10
done
test -n "$shipyard_run_id"
gh run watch "$shipyard_run_id" --exit-status
```

#### Observable Definition of Done

- The ticket exists only under `docs/tickets/complete`, its Status and Ledger
  record honest evidence for both commits, and the lifecycle check exits 0.
- The committed working tree is clean, `origin/main` equals local `HEAD`, and
  `gh run watch --exit-status` exits 0 for that exact commit.

## Acceptance Criteria

- [ ] The captured default command produces a concise digest rather than one
      row per evidence record.
- [ ] An oversized deterministic fixture proves no human output line exceeds
      120 code points and no report exceeds 80 lines.
- [ ] Fleet, attention, effectiveness, priority, and actionable coverage detail
      caps are exactly 10, 5, 8, 5, and 5 respectively.
- [ ] Every capped section reports the exact omitted count and points to
      `--json`.
- [ ] `not_applicable` coverage is summarized but not listed as an actionable
      gap.
- [ ] Displayed attention and priority IDs exist in the JSON source document;
      the five displayed priorities are the first five ranked JSON priorities.
- [ ] Empty sections still render explicitly and all five section headings stay
      in their established order.
- [ ] Compact fleet rows retain health, pressure, and configured safety posture
      without enumerating every operand.
- [ ] `inspect --json` has no schema, value, contents, or ordering change.
- [ ] Invalid invocation behavior and the exit-code/stdout/stderr contract are
      unchanged.
- [ ] The project test gates pass and the repository is clean after commit.
- [ ] The completed change is pushed to `main`, as already authorized by the
      owner for this CLI work.

## Dependencies

- Existing schema-v1 fleet document and deterministic array ordering.
- Existing Bats fixtures and Shipyard inspect gate commands.

## Risks and Mitigations

- **Risk:** clipping hides the operator's only useful clue.
  **Mitigation:** retain stable IDs and state/category fields; make `--json`
  explicit on every omission row.
- **Risk:** a cap accidentally changes ranking semantics.
  **Mitigation:** select from existing document order and assert priority prefix
  equality against JSON.
- **Risk:** readability tests become host-fleet dependent.
  **Mitigation:** enforce the hard contract with synthetic deterministic
  fixtures, then use the live command only as a smoke test.

## Out of Scope

- Changing the installed alias or shell startup files.
- Changing fleet discovery, evidence collection, health derivation, priority
  ranking, schema-v1 JSON, or read-only behavior.
- Adding configuration, a global binary, pager behavior, color, interactive
  TUI output, or a verbose human mode.

## Ledger

The builder appends the phase plan, `builder: subagent (<N> agents)`, commit
hash, exact gate results, live line/width measurement, remote/CI result, and any
honest deferral here before graduation.

## Handoff

Run this ticket with the `execute-ticket` skill. It is decision-complete and
the auto-gate is `PROCEED`.
