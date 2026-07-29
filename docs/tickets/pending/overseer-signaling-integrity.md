# Overseer signaling integrity: findings are healthy runs and notification audits are durable

- **Created:** 2026-07-29
- **Owner:** wabbazzar
- **Status:** Draft — reproduced and root-caused; ready for `polish-ticket`
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 8 (3 phases, each capped at 5)
- **Refs:** `agents/overseer/runner.sh:175-218`,
  `tests/overseer.bats:70-75,138-142`, sibling
  `wabbazzar-ice/scripts/notify.sh:81-139`, sibling
  `wabbazzar-ice/scripts/tests/test_notify_capture.py:28-59`,
  `.agents/gates.md`

## Goal

Restore the integrity of the Overseer's actionable signaling path across
Shipyard and the sibling Ice notification hub: an expected finding must not
make the Overseer unit look broken, and a completed successful Signal transport
must not lose its audit event or captured body when the notifier is the last
process in a supervised service.

## Problem / Background — reproduced acceptance anchors

These are two manifestations of one contract failure: the alert reaches the
owner, but the surrounding operational signal falsely says the producer failed
or silently loses the durable evidence of the send.

### A — an expected Overseer finding fails its systemd unit

A synthetic autonomous project returned a valid unhealthy verdict through a
stub judge and successful stub notification transport:

```text
PATH=<fixture-bin>:$PATH QUARTET_DIR=<shipyard> \
  QUARTET_EVENTS_DIR=<tmp-events> QUARTET_NOTIFY_CMD=<successful-stub> \
  OVERSEER_WALL_CLOCK=5 bash agents/overseer/runner.sh \
  --project <synthetic-autonomous-project>

runner exit=1
{"healthy":false,"status":"problem","summary":"expected synthetic finding",...}
{"event":"overseer.assessed","status":"problem","findings":1}
```

Running that same real runner and fixture under a disposable user transient
service reproduced the systemd failure:

```text
systemd-run --user --wait --collect --unit=<disposable-unit> \
  <the fixture environment and runner command above>

Finished with result: exit-code
Main processes terminated with: code=exited/status=1
systemd-run exit=1
```

The live journal carried the same signature on 2026-07-25, 2026-07-26, and
2026-07-28:

```text
shipyard-overseer.service: Main process exited, code=exited, status=1/FAILURE
shipyard-overseer.service: Failed with result 'exit-code'.
```

**Violated observable contract:** a completed assessment with a real finding
records and notifies `status=problem`, but leaves the oneshot unit healthy.
Failure to assess, malformed judge output, or another internal
`status=error` still fails the unit.

### B — the last notification process can lose both audit records

A disposable user transient service ran the real sibling `notify.sh` against a
local fake HTTP transport. The Signal endpoint returned 201; only the two
background audit-directory operations were delayed:

```text
systemd-run --user --wait --collect --unit=<disposable-unit> \
  <fake-HTTP-201 and isolated audit env> \
  bash <ice>/scripts/notify.sh "repro title" "repro body"

Finished with result: success
Main processes terminated with: code=exited/status=0
HTTP POST: /v2/send 201
notify.send files=0
notify-data files=0
```

With the identical fake transport, paths, permissions, and delayed writers
outside the service teardown, the main script still exited 0, both counts were
zero immediately, and after three seconds both became one with valid JSON:

```text
plain notify exit=0
immediate event=0 body=0
after-3s event=1 body=1
{"event":"notify.send",...,"http":201,"status":"ok",...}
{"title":"plain title","body":"plain title\nplain body","status":"ok"}
```

**Violated observable contract:** when the transport completes successfully,
`notify.sh` does not return until the `notify.send` event and body-capture
record are durably written. Supervised last-process cleanup cannot erase them.

## Root cause and falsified rivals

### A — overloaded domain and execution exit semantics

`agents/overseer/runner.sh:175` correctly distinguishes `ok` from `problem`,
but `:192-201` returns 1 for every non-`ok` verdict and `:205-218` propagates
that code across both single-project and fleet runs. The runner's own contract
at `:30` calls exit 1 “a problem was found,” while a normal `Type=oneshot`
service interprets it as execution failure. The assumption entered with
`1e55dafa` on 2026-07-24.

| Rival cause | Expected if true | Actual | Verdict |
|---|---|---|---|
| Invalid or failed judge | The result/event would be `status=error`, not a parsed finding | Valid unhealthy JSON produced `status=problem`, one finding, and the expected notification | Ruled out |
| Notification transport failure | The transport would be nonzero and drive the runner failure | The fixture transport exited 0; the runner still exited 1 | Ruled out |
| Missing `SuccessExitStatus=1` is the whole defect | Accepting 1 would make findings healthy without masking faults | It makes the transient unit green, but genuine judge/assessment errors also exit 1 today | Ruled out as a complete fix |

The same class has already occurred in the build runner:
`tests/build-benign-abort.bats:2-24` records a benign exit-1 → failed-unit
cascade, corrected at `agents/build/runner.sh:136-153` in `d78cb74`.

**Coverage gap:** `tests/overseer.bats:70-75` deliberately pins `problem` to
exit 1 and `:138-142` pins `error` to the same code. There is no tracked
Overseer unit/install integration contract that asserts the two outcomes have
different service health.

### B — required side effects outlive their owning process

Sibling `wabbazzar-ice/scripts/notify.sh:95-100` backgrounds `notify.send`,
`:107-120` backgrounds the body capture, and `:139` exits immediately with the
foreground curl code. A oneshot service may then remove the remaining cgroup
before either durable write completes. Event backgrounding originated in
`b0f26973` on 2026-04-15 (ampersand adjusted in `226823e5`); body backgrounding
originated in `df1f34f8` on 2026-06-30.

| Rival cause | Expected if true | Actual | Verdict |
|---|---|---|---|
| Signal HTTP/status failure | Missing audits would coincide with failed transport or a nonzero main exit | Local `/v2/send` returned 201 and the main script exited 0; both records were still lost | Ruled out |
| Bad audit paths, permissions, or writer commands | The same isolated paths would never produce valid records | The identical writers produced both valid JSON records after three seconds when allowed to live | Ruled out |

The BopBop thread registration at `notify.sh:126-136` has the same background
lifetime shape. It is best-effort context registration, not a required audit,
but its completion policy must be deliberate and bounded rather than an
accidental orphan.

**Coverage gap:** sibling
`scripts/tests/test_notify_capture.py:28-59` uses a refused transport and polls
for six seconds. `subprocess.run(capture_output=True)` also inherits the
background children's pipes and can wait for them, masking supervisor
teardown. There is no HTTP-200/201 last-process regression case.

## Context / pointers

| Concern | Source |
|---|---|
| Shipyard runner and status propagation | `agents/overseer/runner.sh:175-218` |
| Existing Overseer unit-level fixture tests | `tests/overseer.bats` |
| Prior benign-exit systemd regression | `tests/build-benign-abort.bats` |
| Shipyard gate classes and fleet-live traps | `.agents/gates.md` and `CLAUDE.md` |
| Notification foreground transport and background side effects | sibling `wabbazzar-ice/scripts/notify.sh:81-139` |
| Existing notification capture test | sibling `wabbazzar-ice/scripts/tests/test_notify_capture.py` |
| Sibling shell, systemd, event, notification, and cross-repo gates | sibling `wabbazzar-ice/.agents/gates.md` |

## Decisions

### Locked

| # | Decision | Rationale |
|---|---|---|
| L1 | `problem` is a successful assessment outcome; `error` remains an execution failure | Domain findings are the Overseer's job, not an outage |
| L2 | Do not use `SuccessExitStatus=1` as the sole fix | It would also mask genuine internal errors under the current overloaded code |
| L3 | `notify.send` and body capture are required durable completion work on every attempted send | They are the audit contract consumed by operations and Daily Dispatch |
| L4 | BopBop registration remains successful-send-only, best-effort, bounded by its existing timeout, and unable to change the main transport exit code | Preserve conversation context without widening the notification contract |
| L5 | Do not add or reclassify routine Signal messages | Routine crew news remains in Ice/Daily Dispatch; this ticket repairs integrity, not volume policy |
| L6 | Both regressions are proven red first with synthetic fixtures; live proof uses disposable systemd and fake local HTTP only | No test or build sends real Signal or calls a model |
| L7 | No config flag is introduced | This restores existing stated invariants rather than adding an optional capability |
| L8 | No historical event/body data is synthesized or rewritten | Missing history cannot be reconstructed honestly |

### Open decisions

None. The bugfix intake resolved every build-shaping choice.

### User-decision class

None. The authorized work is local, reversible, and uses no real outward send.

## Technical Requirements

1. Change Shipyard's Overseer status propagation so a parsed unhealthy verdict
   still writes `status=problem`, notifies once through the existing policy,
   and completes successfully, while judge/parse/internal `status=error`
   remains nonzero. Fleet mode must aggregate errors separately from findings.
2. Preserve documented bad-invocation exit 2 and non-autonomous exit 3.
3. Add red-first tests that distinguish `ok`, `problem`, and `error` at both
   runner and disposable oneshot-service boundaries. A test that merely
   configures systemd to accept all exit-1 outcomes is insufficient.
4. In sibling Ice, make the required `notify.send` and body-capture work finish
   before `notify.sh` returns. Preserve the foreground curl result as the
   script's transport exit contract.
5. Treat BopBop registration explicitly: keep it successful-send-only,
   best-effort, and timeout-bounded; joining or otherwise supervising it must
   not make its failure fail Signal delivery.
6. Add a red-first fake-HTTP-200/201 regression that tears down the notifier as
   the last process and asserts nonempty, parseable event and body records.
   Tests must not use the network beyond an isolated loopback fake.
7. Run both repositories' applicable shell/test/public-hygiene gates and the
   sibling event/notification, systemd, and cross-repo gate classes before
   graduation.

## Implementation Plan

### Phase 1 — Separate Overseer findings from execution failure (3 pts)

**Goal:** make expected `problem` verdicts healthy at the process and systemd
layers without hiding assessment errors.

**Delegation:** subagent — implement and red-first test the three-way
`ok`/`problem`/`error` contract, returning changed paths and exact outcome
evidence.

- Add a regression that fails on the captured `problem → exit 1 → failed
  oneshot` defect before changing the runner.
- Separate domain findings from internal errors in single-project and fleet
  exit aggregation.
- Preserve notification/event payloads and the exit-2/exit-3 contracts.
- Apply Shipyard's shell, bats, systemd, delegation, and public-hygiene gate
  classes. This phase is independently committable in Shipyard.

### Phase 2 — Make Ice notification audits last-process durable (3 pts)

**Goal:** make successful notification completion include durable audit event
and body records, with BopBop registration deliberately bounded.

**Delegation:** subagent — work in the sibling Ice repo on the notifier and its
tests, returning red/green last-process evidence and the selected BopBop
lifecycle behavior.

- Add the fake-success, supervisor-teardown regression first and record its
  failure against the current notifier.
- Make both required audit writers complete before the script returns without
  changing the foreground curl exit contract.
- Preserve BopBop's successful-send-only, best-effort semantics while ensuring
  its child-process lifecycle is intentional and bounded.
- Apply Ice's shell, event/notification, systemd, and relevant test gate
  classes. This phase is independently committable in the sibling repo.

### Phase 3 — Cross-repo live proof and ticket graduation (2 pts)

**Goal:** prove the complete alert path under real supervision without an
outward send, then graduate the ticket.

**Delegation:** subagent — independently audit both commits and their same-class
surfaces, returning only contract deviations and gate evidence.

- Re-run the two captured reproductions with disposable user transient units,
  stubbed Overseer transport, and local fake HTTP 200/201.
- Confirm `problem` leaves the unit healthy, `error` fails it, successful
  notify writes both durable records before exit, and a BopBop failure cannot
  change the Signal transport result.
- Run both repositories' complete applicable gates and confirm both worktrees
  are clean at their phase boundaries.
- Graduate this ticket from `pending/` to `complete/` only after both
  repository changes and the cross-repo proof are complete.

## Testing Strategy

- **Red-first regression:** every new contract case is shown failing against
  the unfixed code for the captured reason, then green after the minimum fix.
- **Shipyard:** extend the hermetic Bats Overseer surface; run the configured
  Bats, syntax, leak, and deck-fresh gates even though no deck change is
  expected.
- **Ice:** extend the existing notification capture tests with a loopback fake
  success and last-process supervisor teardown; apply its shell,
  event/notification, and systemd gate classes.
- **Cross-repo:** use only disposable units, temporary fixture directories,
  stub notification commands, and local fake HTTP. Never send real Signal,
  invoke a model, rewrite live data, or wait for a scheduled timer.

## Roll-up Definition of Done

- [ ] The original valid unhealthy Overseer fixture records/notifies
  `status=problem` and returns success.
- [ ] A disposable oneshot running that fixture finishes healthy.
- [ ] A judge/parse/internal `status=error` still returns nonzero and fails the
  disposable oneshot.
- [ ] Fleet mode remains healthy for findings-only runs and nonzero when any
  assessment has an internal error.
- [ ] No `SuccessExitStatus=1`-only masking fix is used.
- [ ] The original fake-HTTP-success last-process fixture exits with the
  transport result and leaves nonempty, parseable `notify.send` and body JSONL.
- [ ] BopBop registration is successful-send-only, best-effort, bounded, and
  unable to alter the main Signal transport exit result.
- [ ] Regression tests were captured red before implementation and green after.
- [ ] Shipyard and Ice applicable gates are green and both worktrees are clean.
- [ ] No real Signal/model/network call, historical data rewrite, dashboard
  edit, or routine-message expansion occurred.
- [ ] The ticket is moved to `docs/tickets/complete/` only after both repos and
  live disposable proofs are complete.

## Dependencies

- **Sibling repository:** the notification durability change lands in
  `wabbazzar-ice`.
- **External services:** none; verification uses local fakes and disposable
  user units.
- **Blocked by:** none.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| A broad “exit 1 is success” rule hides genuine Overseer outages | Separate `problem` from `error` in runner semantics and assert both under systemd |
| Waiting for audit children increases notify latency or changes curl status | Bound only the already-bounded BopBop path; preserve the foreground curl code explicitly |
| Cross-repo work lands half-complete | Keep Phases 1 and 2 independently green/committable; run Phase 3 only after both are present |
| A regression test sends Signal or touches live data | Require isolated temp roots, stub transport, and loopback fake HTTP |
| Fleet-live Shipyard edits affect scheduled agents before verification | Follow the main-checkout coordination rule and complete all applicable gates before commit |

## Out of scope

- Changing notification classification, deduplication, wording, cadence, or
  routine-message volume.
- Dashboard, Daily Dispatch, or Ice newspaper work.
- Reconstructing or rewriting historical event/body records.
- Replacing Signal or BopBop transports.
- Making `SuccessExitStatus=1` the standalone Overseer fix.
- General redesign of shell background-job policy outside the three identified
  notifier children.

## Ledger

### Phase 1 — Separate Overseer findings from execution failure

- plan:
- builder:
- RED:
- verification:
- commit:

### Phase 2 — Make Ice notification audits last-process durable

- plan:
- builder:
- RED:
- verification:
- commit:

### Phase 3 — Cross-repo live proof and ticket graduation

- plan:
- builder:
- verification:
- Shipyard commit:
- Ice commit:
- graduation:
