# Dashboard service identity reconciliation

- **Created:** 2026-07-31
- **Owner:** wabbazzar
- **Status:** polished — ready to execute
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 2
- **Refs:** `dashboard/reader.py`, `dashboard/tests/test_reader.py`,
  `dashboard/tests/browser.mjs`, `dashboard/tests/fixtures/browser-seed.json`

## Summary

Reconcile lifecycle events that omit `project` with their unambiguous named
project so the operations dashboard renders one service row per real
project/role instead of splitting starts and ends across duplicate rows. Keep
non-lifecycle evidence such as dashboard smoke events out of Service watch.

## Problem / Background

The real development-browser reproduction against the installed loopback
dashboard returned 13 service rows: six rows with a blank project, the same six
services under `dochound` or `judgify`, and the dashboard smoke row. The actual
topology is two Shipyard installations with three observed lifecycle roles
each, so the observable Service watch result must be six rows.

Reproduction on the pre-fix branch:

1. `curl /api/summary?window=7d` returned 13 services.
2. Chromium DOM inspection returned 13 desktop table rows and 13 narrow cards,
   including six blank-project entries.
3. The event API contained exactly seven unique `svc` values and no aliases.
   Each lifecycle start had a named project while its corresponding terminal
   event omitted `project`.

The front end is ruled out: `dashboard/static/app.js:100-122` maps API services
one-for-one, and DOM/API row counts matched exactly. Service aliases are ruled
out because the real stream has no alternate `svc` spelling.

Root cause:

- **Where:** `EventReader.summarize()` at `dashboard/reader.py:410-454` keys
  every event by exact `(project, role, svc)`, so empty and named projects split.
- **When:** the behavior entered with the initial bounded reader commit
  `82d51dc`; `git blame dashboard/reader.py:410-470` attributes both summary
  and actionable service keys to that commit.
- **Elsewhere:** `_actionables()` at `dashboard/reader.py:463-470` repeats the
  same exact identity assumption and can fail to reconcile a terminal failure.
- **Adjacent root:** `summarize()` seeds `activity` from every event, so a
  non-lifecycle `dashboard.smoke` row becomes a fictitious service.
- **Why missed:** the synthetic lifecycle fixtures use complete identity on
  every row. The only missing-project test covers a standalone event, and the
  browser harness asserts layout but not real topology cardinality.

## Technical Requirements

- Within one summary window, derive candidates from events with a non-empty
  canonical project, indexed by exact `(role, svc)`.
- When an event has no project and its exact `(role, svc)` maps to one and only
  one named project, use that project for derived service state and failure
  reconciliation.
- When the mapping is absent or ambiguous, preserve the empty project. Never
  infer identity by parsing the display-oriented `svc` string.
- Apply the same reconciled key to summary state and failed-actionable state.
- Include a Service watch identity only when the window contains `job.start` or
  `job.end` for it. Other events may update last activity for an already-known
  lifecycle identity but may not create a service row.
- Preserve raw event rows and filters exactly; reconciliation affects derived
  summaries only and never rewrites JSONL history.
- Extend the browser fixture with a mixed-completeness lifecycle and assert one
  rendered service per logical identity at both declared viewports.
- Update `.agents/gates.md` so the dashboard is a served-app surface and every
  UI/UX completion claim requires development-browser semantic assertions
  against the live page in addition to visual screenshot inspection.

## Decisions

| Decision | State | Rationale |
|---|---|---|
| Reconcile only an exact `(role, svc)` with exactly one named project | locked | Preserves canonical identity without parsing a display name. |
| Keep absent/ambiguous project empty | locked | Unknown evidence must remain honest rather than guessed. |
| Service watch contains lifecycle identities only | locked | Incidents and smoke are evidence, not installed services. |
| Preserve raw JSONL and raw event API bytes | locked | The dashboard is a read-only derived view. |
| Development-browser semantic checks join screenshots as a UI gate | locked | Visual plausibility did not catch the shipped topology defect. |

There are no open decisions and no user-decision-class changes. The fix is
local, read-only, reversible, and does not change external behavior or routing.

## Implementation Plan

### Phase 1 — Reconcile identity and prove the rendered topology (2 pts)

Implement one bounded identity resolver in `dashboard/reader.py`, use it for
service state and actionable failures, add focused reader regressions for
unambiguous, absent, and ambiguous mappings, then strengthen the browser fixture
and harness to assert service cardinality and no blank-project split.

Delegation: subagent — from the captured 13-row live reproduction, modify only
`dashboard/reader.py`, `dashboard/tests/test_reader.py`,
`dashboard/tests/fixtures/browser-seed.json`, `dashboard/tests/browser.mjs`, and
`.agents/gates.md`. Implement unambiguous exact-key reconciliation, lifecycle-
only Service watch membership, reader guards for absent/ambiguous mappings,
and exact browser service-card/table assertions. Return at most 40 lines:
files changed; commands and exit codes; pre-fix RED and post-fix GREEN evidence;
browser row/card counts; blockers. Converge honestly or report the precise
blocker with the actual evidence — NEVER fake green, weaken a check, or
hand-wave "should work". Run the real command, read the real file, curl the
real port, and report exact output (exit codes, JSONL lines, HTTP codes), not
adjectives. If it needs a spend, an outward-facing action, or a destructive
change, stop and report instead.

## Testing Strategy

- Reader regression fails on the captured mixed `job.start`/`job.end` identity
  before the fix and passes afterward.
- Guard cases prove a standalone missing project stays empty and an ambiguous
  `(role, svc)` mapping is never guessed.
- Browser harness proves the synthetic topology at `1440×900` and `390×844`.
- A live development-browser pass against the installed service proves exactly
  six rows, no blank-project service rows, correct consolidated state, and
  the expected responsive table/card presentation.
- Run the canonical Python, browser, full Bats, syntax, leak, deck, lifecycle,
  and diff gate classes.

### Exact verification surface

1. Pre-change RED: the focused reader regression must report two identities
   for one mixed-completeness lifecycle and the live browser must report
   `DOM_ROW_COUNT=13`, `BLANK_PROJECT_ROWS=6`.
2. Focused Python:
   `python3 -m unittest -v dashboard.tests.test_reader dashboard.tests.test_server`
   and the same command with `/usr/bin/python3`.
3. Synthetic development browser at both declared viewports:
   `node dashboard/tests/browser.mjs --browser chromium --viewport 1440x900 --screenshot-dir <tmp-wide>`
   and the equivalent `390x844` command. Inspect both images; exact service
   identities and cardinality must be asserted by the harness, not eyeballed.
4. Reinstall/restart the real launchd service from this branch:
   `/bin/bash scripts/install-dashboard.sh --install --port 8766`, then
   `/bin/bash scripts/install-dashboard.sh --doctor --port 8766`.
5. Real API: `curl -fsS 'http://127.0.0.1:8766/api/summary?window=7d'` must show
   six services: `dochound` and `judgify` × `build`, `medic`, `release`; no
   empty project and no `dashboard` role.
6. Real development browser at 1440×900 and 390×844 must assert the same six
   table rows/cards in the live DOM, zero console errors, no overflow, and only
   `http://127.0.0.1:8766` request origins. Inspect both screenshots.
7. Full gates: native `bats tests/`, Bash/Python/JavaScript syntax, reader
   benchmark, leak, deck freshness/completeness/render, lifecycle, delegation,
   and `git diff --check`. End with no headless browser process and a ready
   launchd service.

## Acceptance Criteria / Definition of Done

- [ ] The captured pre-fix reproduction changes from 13 service rows with six
      blank-project duplicates and one smoke-only row to six lifecycle rows
      with neither defect.
- [ ] `dochound` and `judgify` each render exactly one build, medic, and release
      row, with terminal status/duration/activity consolidated correctly.
- [ ] Missing project is reconciled only for one unambiguous `(role, svc)`
      candidate; absent and ambiguous candidates remain empty.
- [ ] Summary and failed-actionable derivation use the same resolved identity.
- [ ] Non-lifecycle-only identities stay in event/actionable evidence and do
      not appear as Service watch rows.
- [ ] Raw event queries and the append-only JSONL source remain unchanged.
- [ ] Development-browser inspection passes at 1440×900 and 390×844 with
      correct row/card counts, responsive composition, no browser console
      errors, and only same-origin requests.
- [ ] The installed macOS service is restarted from the changed source, reports
      ready on loopback, and no proof browser process remains afterward.
- [ ] Focused and full repository gates are green and the worktree is clean.

## Dependencies

- The completed local operations dashboard branch and its running loopback
  service.
- External services: none.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| A shared display service name is misattributed | Require exactly one named project for exact `(role, svc)`; ambiguity stays unknown. |
| Derived identity leaks into raw evidence | Keep reconciliation local to summary/actionable derivation; checksum raw fixtures and real event history. |
| A visually plausible table still lies about topology | Assert exact API and DOM cardinality plus named row contents in a development browser. |

## Out of scope

- Rewriting historical event rows or changing runner emission in this ticket.
- Parsing project names from `svc`.
- Hiding unknown or ambiguous identities in the UI.
- Any push, tunnel, receive-workmac routing, or merge.

## Ledger

| Phase | Plan | Builder | Commit | Evidence / notes |
|---|---|---|---|---|
| 1 — identity reconciliation and rendered proof | Resolve only unambiguous missing-project lifecycle identity, exclude non-lifecycle-only services, close reader/browser coverage, update the served-app gate, verify synthetic and real viewports, restart the intended loopback service, and graduate this ticket. | pending | pending | Pre-fix evidence: API 13 services; desktop DOM 13 rows; narrow DOM 13 cards; six blank-project duplicates; one smoke-only service row; seven unique `svc` values with no aliases. Root cause and two rivals independently probed 2026-07-31. |

Run this ticket with the `execute-ticket` skill.
