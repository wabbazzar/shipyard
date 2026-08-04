# Make degraded operator evidence impossible to mistake for a healthy fleet

- **Created:** 2026-08-04
- **Owner:** wabbazzar
- **Status:** pending
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 11 (three phases: 3 · 5 · 3)
- **Refs:** `dashboard/operator.py:2045-2231`,
  `dashboard/operator.py:2408-2472`, `dashboard/operator.py:2545-2619`,
  `dashboard/operator.py:2910-2947`, `dashboard/static/app.js:82-143`,
  `dashboard/static/app.js:164-239`, `dashboard/static/app.js:490-497`,
  `skills/shipyard/shipyard.sh:306-337`,
  `skills/shipyard/inspect.py:1174-1280`,
  `dashboard/tests/test_operator.py:1456-1467`,
  `dashboard/tests/browser.mjs:425-449`,
  `docs/tickets/complete/operator-outcomes-dashboard.md:26-35`

## Summary

Restore the operator dashboard's locked truthfulness contract under partial or
failed inspection. The dashboard must keep independently measured runtime facts
usable, but must never turn unavailable inspection into zero attention, a
healthy-sounding takeaway, all-green coverage, or dead evidence controls.

## Objective

When fleet inspection cannot run or returns partial evidence, both
`GET /api/operator` and the rendered dashboard identify exactly what cannot be
assessed, preserve known runtime outcomes as qualified facts, expose the local
recovery action, and link every event-derived aggregate to bounded evidence.

## Problem / Background

### Captured reproduction — live Mac dashboard, 2026-08-04

The installed dashboard is ready and its event stream is connected, but its
inspection cache is unavailable. This read-only contract probe fails against
the real `127.0.0.1:8766` service:

```bash
set -o pipefail
curl -fsS 'http://127.0.0.1:8766/api/operator?window=7d' |
  jq -ce '(.brief.signals[]|select(.id=="attention")) as $a |
    {inspection:.metadata.inspection_state,
     takeaway:.brief.takeaway,
     attention:[$a.value,$a.observed,$a.total],
     operator_attention:.outcomes.operator_load.attention_items,
     promises:[.promises[].state]|unique,
     reliability:[.outcomes.reliability.successful,
                  .outcomes.reliability.completed]} |
    if .inspection=="unavailable" and
       (.takeaway=="No operator action is currently evidenced" or
        (.operator_attention==null and .attention==[0,0,0]) or
        (.reliability[0] < .reliability[1]))
    then error("degraded evidence rendered as no-action/zero: \(.)")
    else . end'
```

Observed output and exit:

```text
jq: error (at <stdin>:1): degraded evidence rendered as no-action/zero: {"inspection":"unavailable","takeaway":"No operator action is currently evidenced","attention":[0,0,0],"operator_attention":null,"promises":["unverified"],"reliability":[12,24]}
exit 5
```

The same document contains 65 event evidence rows but zero evidence references
from any promise, outcome, graph, attention group, or story beat. All five
rendered coverage rows say `available · ok`; the unavailable inspection source
is omitted. The UI repeats disabled `Review 0 records` controls.

### Violated observable contract

The completed operator-dashboard ticket locks these invariants:

- Missing evidence stays visible; unknown must never collapse into healthy,
  successful, or zero
  (`docs/tickets/complete/operator-outcomes-dashboard.md:108`).
- The browser presents supplied semantics rather than deriving KPI meaning
  (`docs/tickets/complete/operator-outcomes-dashboard.md:26-35`).
- Every claim and aggregate exposes bounded evidence IDs or an explicit
  limitation (`docs/tickets/complete/operator-outcomes-dashboard.md:570-577`).

### Root cause and rival causes

| Candidate | Expected / actual evidence | Verdict |
|---|---|---|
| Frontend coerces nulls to zero | `present(null)` returns `—`, and `renderBrief()` renders the API values verbatim (`dashboard/static/app.js:38-41`, `:119-143`). The live API already contains the contradiction. | Ruled out as primary. |
| No runtime evidence exists | Live operator data measures 12 successful of 24 completed runs and retains 65 event rows. | Ruled out. |
| Composer treats missing inspection as an observed empty set | `_attention_rows(None)` returns no rows; `_brief_document()` then uses `len(grouped)` for `0/0` and hard-codes the no-action fallback (`dashboard/operator.py:620-623`, `:2594-2612`). | Ruled in. |
| Launchd inspection uses the dashboard's Python 3.11 | The LaunchAgent starts `python3.11`, but `make_expensive_loader()` shells into `shipyard.sh`, whose `cmd_inspect()` resolves ambient `python3`. Under the LaunchAgent PATH, `/usr/bin/python3` fails importing `tomllib`; interactive Python 3.11 inspection succeeds. | Ruled out; interpreter provenance is lost. |

### Four root-cause answers

- **Where:** interpreter provenance is lost at the dashboard-to-shell boundary,
  and `_brief_document()` independently conflates unavailable attention with an
  observed empty attention set.
- **When:** the brief fallback entered with commit `5d1757b7` on 2026-08-02;
  launchd inspection became observable when the operator dashboard began
  invoking fleet inspection in the background.
- **Elsewhere:** coverage omits absent inspector/relationship sources;
  event-derived reliability and role contracts omit evidence IDs; the client
  euphemizes failed inspection as “still loading” and repeats dead controls.
- **Why missed:** unavailable-inspection unit coverage asserts promises,
  topology, and metadata but not brief/coverage semantics; browser coverage
  waits through the unavailable document and asserts only the later fresh one.

## Design intent

- **Subject / audience / job:** fleet evidence for the local Shipyard operator,
  who must decide in ten seconds whether to act, wait, or restore inspection.
- **Thesis:** evidence confidence is the first reading layer—known facts lead,
  unavailable data blocks reassurance, and every actionable claim has a direct
  record trail.
- **Hierarchy:** degraded inspection or a known alarm precedes routine measured
  activity; recovery copy precedes secondary metrics; raw evidence remains a
  drill-down, not the primary reading task.
- **Existing visual system:** preserve Hull `#0a0906`, Chalk `#f6ecd8`, Signal
  `#ff9247`, Clear `#8fe0a0`, Waiting `#f5c866`, and Alarm `#ff8a8a`; preserve
  system display/body type and monospaced utility type. Do not introduce a new
  theme or decorative component family.
- **Responsive proof:** inspect both `1440×900` and `390×844`; narrow mode must
  recompose the hierarchy without horizontal overflow or clipped status copy.

## Technical Requirements

1. Preserve the Python interpreter selected by `install-dashboard.sh` across
   the background inspection boundary. `shipyard inspect` remains a portable
   public CLI, but an embedding Python process can supply its exact interpreter
   without relying on launchd's ambient PATH.
2. An unavailable inspection produces nullable attention counts and an
   `inspection_unavailable` limitation. It cannot produce an observed `0/0`.
3. Brief precedence must consider independently measured alarms. A measured
   runtime alarm may lead with qualified evidence; otherwise unavailable
   inspection leads with explicit inability-to-assess and recovery copy.
4. Coverage contains explicit unavailable rows for missing inspection and
   relationship snapshots. Collector availability and observed-record coverage
   remain distinguishable.
5. Reliability and per-role event aggregates expose bounded `evidence_ids`
   using the existing safe event-evidence IDs and `_bound_evidence()` closure.
   Do not invent joins or opaque identifiers absent from source events.
6. The browser renders human-facing limitation/reason labels, calls failed
   inspection unavailable rather than merely loading, and does not render a
   disabled review action when no linked evidence exists.
7. Preserve ordering, schema version, redaction, response bounds, same-origin
   traffic, keyboard operation, contrast, reduced motion, and SSE restoration.

## Implementation Plan

### Phase 1 — Preserve inspection interpreter provenance (3 pts)

- Add an explicit, validated interpreter override at the `shipyard inspect`
  boundary and pass `sys.executable` from `make_expensive_loader()`.
- Add a hermetic test whose ambient `python3` cannot import the inspector while
  the supplied interpreter can; prove the background loader returns inspection
  rather than `inspection_refresh_failed`.
- Keep direct interactive `shipyard inspect --json` behavior unchanged.
- Files: `skills/shipyard/shipyard.sh`, `dashboard/operator.py`, focused tests
  under `tests/` and/or `dashboard/tests/`.
- Delegation: subagent — implement interpreter-provenance behavior and its
  hermetic regression test; return files, commands/exits, and the RED/GREEN
  signature in at most 40 lines.
- Proving it works: focused shell/operator tests plus syntax/compile gates show
  the wrong ambient interpreter can no longer poison the cache.

### Phase 2 — Restore truthful operator semantics and evidence closure (5 pts)

- Make unavailable attention nullable and limitation-bearing.
- Define deterministic brief precedence for measured alarms versus unavailable
  inspection, without deriving meaning in the browser.
- Emit explicit missing inspection/relationship coverage rows.
- Attach bounded event evidence to reliability and role-contract aggregates;
  keep unprovable promises and topology overlays explicitly limited.
- Add unit cases that fail on the captured unavailable-inspection contradiction,
  cover the measured-alarm case, and assert every emitted evidence link closes
  over the bounded evidence set.
- Files: `dashboard/operator.py`, `dashboard/tests/test_operator.py`.
- Delegation: subagent — implement and regression-test the pure composer slice;
  return files, commands/exits, exact JSON assertions, and blockers in at most
  40 lines.
- Proving it works: the deterministic fixture and live-shaped contract probe
  no longer report no-action/zero under unavailable inspection.

### Phase 3 — Make degraded state legible in the real UI (3 pts)

- Replace loading euphemism with explicit unavailable/retry state when refresh
  has failed; humanize limitation and coverage copy.
- Omit zero-evidence review buttons while keeping nonzero evidence navigation.
- Extend browser coverage to hold the unavailable document long enough to
  assert Outcomes semantics, alarm hierarchy, coverage, controls, and both
  desktop/narrow screenshots before allowing a fresh response.
- Reinstall/restart the dashboard on an unused local port first, then verify the
  installed `127.0.0.1:8766` surface only after the hermetic proof is green.
- Files: `dashboard/static/app.js`, optionally `dashboard/static/index.html`
  and `dashboard/static/styles.css`, `dashboard/tests/browser.mjs`, dashboard
  smoke tests, and this ticket Ledger.
- Delegation: subagent — implement the presentation/test slice under the design
  thesis; return changed files, browser assertions, screenshot paths, process
  cleanup, commands/exits, and blockers in at most 40 lines.
- Proving it works: real Chrome at `1440×900` and `390×844`, visual inspection,
  zero overflow/errors/off-origin traffic, and no surviving browser process.

## Testing Strategy

- Failure-first unit regression in `dashboard/tests/test_operator.py` for
  unavailable inspection + measured failed terminal evidence.
- Hermetic shell/Python regression for launchd-like PATH and explicit
  interpreter provenance.
- `python3 -m unittest -v dashboard.tests.test_operator
  dashboard.tests.test_reader dashboard.tests.test_server`.
- `bats tests/dashboard.bats tests/shipyard-status.bats
  tests/shipyard-inspect.bats`, followed by `bats tests/`.
- `node dashboard/tests/browser.mjs --browser chromium --viewport 1440x900
  --screenshot-dir <fresh-temp-dir>` and the `390x844` equivalent.
- `bash -n install.sh agents/lib/*.sh agents/*/runner.sh
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit` and
  `python3 -m py_compile dashboard/*.py skills/shipyard/inspect.py`.
- `bash scripts/leak-check.sh`, `bash scripts/check-deck-fresh.sh`,
  `git diff --check`, and `bash scripts/ticket-lifecycle.sh --project . --check`
  (exit `3` remains the documented flat-layout no-op on this Mac lineage).
- Installed proof: dashboard doctor clean, `/api/health` ready, degraded and
  recovered `/api/operator` states truthful, then real-browser screenshots and
  explicit headless-process cleanup.

## Acceptance Criteria / Definition of Done

- [ ] The captured live-shaped reproduction cannot produce no-action or numeric
      zero attention when inspection is unavailable.
- [ ] A launchd-like minimal PATH cannot select an incompatible Python after the
      dashboard has already selected a compatible interpreter.
- [ ] Known reliability alarms remain visible and qualified when inspection is
      unavailable; unknown data never overrides or falsifies known facts.
- [ ] Missing inspection and relationship sources appear explicitly in coverage.
- [ ] Every event-derived reliability/role claim links to bounded evidence, and
      every emitted ID resolves to exactly one response evidence object.
- [ ] Zero-evidence claims explain the limitation without a disabled
      `Review 0 records` control.
- [ ] Limitation/reason copy is human-readable; stable API codes remain in the
      document for machines.
- [ ] Desktop and narrow browser proofs pass with zero overflow, console/page/
      request errors, external origins, mutation controls, or surviving browser
      processes; screenshots are visually inspected.
- [ ] Focused and full repository gates pass, the installed dashboard is ready,
      and the worktree is clean at the phase boundary.
- [ ] No GitHub push originates from the Mac. After this ticket and
      `specialist-shoulder-polish-routing` are complete, exact commits and merge
      order are handed to `receive-workmac` over `wab` for PR/merge work.

## Boundaries

### Always

- Preserve unknown/unavailable semantics and independently known runtime facts.
- Use existing redaction, bounds, evidence IDs, UI tokens, and same-origin API.
- Add a regression capable of failing on the real pre-fix defect.

### Ask first

- Any schema-version bump or breaking change to the Ice consumer contract.
- Any change that mutates raw event history or live scheduler configuration.
- Any outward-facing GitHub action; this Mac remains push-disabled.

### Never

- Never infer project ownership from service-name string splitting.
- Never add a top-level dependency, client-side KPI derivation, second operator
  endpoint, or alternate dashboard implementation.
- Never weaken the unavailable-state, evidence-closure, browser, leak, or full
  repository gates to make the ticket pass.

## Dependencies

- Coordinate only at file/commit boundaries with the concurrent
  `specialist-shoulder-polish-routing` build; do not edit its ticket or
  specialist files.
- Final PR/merge handoff waits for both tickets. No implementation dependency
  exists between them.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Fixing only the banner leaves the API misleading | Pin the pure operator document before browser work. |
| Interpreter override becomes an injection surface | Accept one executable path as one argv element; never evaluate shell text. |
| Evidence links expand the response beyond bounds | Reuse safe event IDs and the existing `_bound_evidence()` closure. |
| Known controlled aborts are presented as outages | Preserve the measured rate and terminal reasons as facts; do not invent impact or remediation. |
| Concurrent specialist work is swept into a commit | Check status/log immediately before each commit and stage explicit paths only. |
| Installed proof serves stale assets | Reinstall/restart, compare source revision/digest, curl health, then render. |

## Out of Scope

- Adding `project_id`, `run_id`, or `job_id` to producers; inferring those IDs
  from `svc`; redesigning the entire event schema.
- Search, filtering, pagination, or a new information architecture for the raw
  Evidence browser.
- Reworking the configured architecture topology or declaring static nodes
  observed without evidence.
- Fixing unrelated doctor findings inside `dochound`.

## Ledger

Builder appends the phase plan, `builder:` line, commit hash, exact gate output,
rendered screenshot paths, and honest blockers here before each phase commit.

---

Run with `execute-ticket` after `polish-ticket` hardens the phase gates and
records any specialist verdict required by the installed manifests.
