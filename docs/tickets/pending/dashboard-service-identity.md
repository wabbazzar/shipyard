# Dashboard service identity reconciliation

- **Created:** 2026-07-31
- **Owner:** wabbazzar
- **Status:** draft
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

## Implementation Plan

### Phase 1 — Reconcile identity and prove the rendered topology (2 pts)

Implement one bounded identity resolver in `dashboard/reader.py`, use it for
service state and actionable failures, add focused reader regressions for
unambiguous, absent, and ambiguous mappings, then strengthen the browser fixture
and harness to assert service cardinality and no blank-project split.

Delegation: subagent — implement the bounded reader/tests/browser-fixture slice
and return changed files, exact test/browser outputs, and blockers in at most
40 lines.

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
