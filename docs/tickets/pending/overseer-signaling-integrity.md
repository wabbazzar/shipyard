# Overseer signaling integrity: findings are healthy runs and notification audits are durable

- **Created:** 2026-07-29
- **Owner:** wabbazzar
- **Status:** Polished — ready for `execute-ticket`
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

### Repository state and workflow (measured while polishing, 2026-07-29)

- **Shipyard:** canonical checkout, branch `main`; work directly on `main`.
  `CLAUDE.md` forbids branches/worktrees because commits from a worktree can
  relink the fleet. Existing unrelated changes in
  `agents/release/role.md`, `agents/release/runner.sh`, and
  `tests/release-blocking-gate.bats` belong to another task: do not edit,
  stage, revert, or commit them. Use explicit `git add` paths, never `-A`.
- **Ice:** sibling checkout `../wabbazzar-ice`, branch `master`, clean when
  polished. Work directly on `master`; before writing, confirm it remains
  clean. Commit its Phase 2 atomically before returning to Shipyard Phase 3.
- Both checkouts are live operational surfaces. Never use a real notification
  transport in this ticket; all execution uses PATH stubs or loopback HTTP.

### Toolchain baseline (run while polishing, 2026-07-29)

```text
bats tests/overseer.bats
→ 8/8 passed, rc=0

cd ../wabbazzar-ice &&
  .venv/bin/python -m pytest scripts/tests/test_notify_capture.py -q
→ 1 passed, rc=0

systemd-run --user --wait --collect \
  --unit=polish-signal-integrity-<unique> /bin/true
→ Finished with result: success; status=0; rc=0
```

The user systemd manager, Bats, Ice's uv-managed Python environment, pytest,
and transient-service surface therefore exist. Do not install dependencies.

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
| L9 | Shipyard work is direct on `main`, with no branch/worktree; Ice work is direct on `master` | These are the repositories' explicit operating rules for this build |
| L10 | Preserve and exclude the three unrelated dirty Shipyard paths named in Repository state | Two agents share the canonical live checkout; scope every add/commit |

### Open decisions

None. The bugfix intake resolved every build-shaping choice.

### User-decision class

None. The authorized work is local, reversible, and uses no real outward send.

## Technical Requirements

1. Change Shipyard's Overseer status propagation so a parsed unhealthy verdict
   still writes `status=problem`, notifies once through the existing policy,
   and completes successfully, while judge/parse/assessment-infrastructure
   `status=error` remains nonzero. Fleet mode must aggregate errors separately
   from findings.
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

## Traps this build must pin

- Preserve the three unrelated dirty Shipyard paths; explicit adds only.
- Never make exit 1 universally successful: prove `problem` and `error` under
  identical normal oneshot policy.
- Redirect child descriptors in the Ice regression; inherited pipes can make
  `capture_output=True` wait and hide the last-process race.
- Inspect isolated UTC-dated event JSONL, not a local-date guess.
- Clean unique transient units, fake servers, and delayed children even when a
  test fails; empty final unit/process queries are gate evidence.

## Implementation Plan

### Phase 1 — Separate Overseer findings from execution failure (3 pts)

**Goal:** make expected `problem` verdicts healthy at the process and systemd
layers without hiding assessment errors.

**Delegation: subagent — bounded build brief (≤40-line return).**

> Work only in Shipyard on `main`. Own `agents/overseer/runner.sh`,
> `tests/overseer.bats`, and this ticket's Phase 1 Ledger fields. Do not touch
> or stage the unrelated release-role/runner/blocking-gate paths. First change
> or add exact Bats cases named `unhealthy crew: status=problem is a successful
> assessment` and `assessment infrastructure failure remains nonzero`; add fleet
> mixed-outcome coverage. Run the problem case against pre-change code and
> record meaningful RED. Then make parsed findings return 0 while assessment /
> infrastructure errors remain nonzero in both single and fleet modes.
> Preserve events, one successful-stub notification, exit 2, and exit 3.
> Return ≤40 lines: files; RED/GREEN commands and exits; test counts; exact
> problem/error event and process-status evidence; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**RED first (before runner edit):**

```bash
bats --filter \
  'unhealthy crew: status=problem is a successful assessment' \
  tests/overseer.bats
```

It must fail because the current valid `problem` exits 1. Separately run the
pre-existing error test as a guard; it must pass before the edit:

```bash
bats --filter 'judge returns no usable verdict' tests/overseer.bats
```

**Focused GREEN and observable contract:**

```bash
bats tests/overseer.bats tests/build-benign-abort.bats
bash -n agents/overseer/runner.sh
```

The focused output must show: valid unhealthy JSON + successful notify stub →
`overseer.assessed status=problem`, exactly one notification, process rc=0;
unusable/failed assessment → `status=error`, process rc nonzero; findings-only
fleet rc=0; any-error fleet rc nonzero; unknown arg rc=2; non-autonomous rc=3.

**Disposable systemd proof (no live unit, model, or Signal):**

Add local-only Bats cases named `systemd problem verdict leaves oneshot
healthy` and `systemd error verdict fails oneshot`. They must use
`systemd-run --user --wait --collect`, a unique unit name, synthetic project,
PATH judge stub, successful notify stub, and temp event root. Skip with an
explicit reason only when the user systemd manager is unavailable.

```bash
bats --filter \
  'systemd (problem verdict leaves oneshot healthy|error verdict fails oneshot)' \
  tests/overseer.bats
systemctl --user list-units 'overseer-test-*' --all --no-legend
```

The first case must contain `Finished with result: success` and status 0; the
second must contain `Finished with result: exit-code` and a nonzero status.
The final list must be empty; `--collect` is mandatory.

**Full Shipyard gate before the Phase 1 commit:**

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py scripts/delegation-report.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
git diff --check -- agents/overseer/runner.sh tests/overseer.bats \
  docs/tickets/pending/overseer-signaling-integrity.md
git status --short
```

The status may still show the three pre-existing unrelated paths; it must show
no other unexplained path. Commit only the Phase 1-owned paths explicitly.

### Phase 2 — Make Ice notification audits last-process durable (3 pts)

**Goal:** make successful notification completion include durable audit event
and body records, with BopBop registration deliberately bounded.

**Delegation: subagent — bounded sibling build brief (≤40-line return).**

> Work only in clean sibling `../wabbazzar-ice` on `master`. Own
> `scripts/notify.sh`, `scripts/tests/test_notify_capture.py`, and this ticket's
> Phase 2 Ledger fields (the orchestrator writes the Ledger in Shipyard).
> Before editing, add `test_successful_last_process_persists_audits_before_exit`
> using isolated temp roots, a loopback 201 server, delayed audit children, and
> last-process teardown; show it RED. Add a user-systemd companion test, skipped
> only without a user manager. Make notify.send and body capture synchronous
> completion work. Explicitly supervise BopBop's existing successful-send-only,
> `-m 3`, best-effort registration; its failure must not alter the Signal curl
> rc. Send no real Signal. Return ≤40 lines: files; RED/GREEN commands and
> exits; HTTP/status/JSONL evidence; test counts; background cleanup; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**RED first (before notifier edit):**

```bash
cd ../wabbazzar-ice
.venv/bin/python -m pytest \
  scripts/tests/test_notify_capture.py::test_successful_last_process_persists_audits_before_exit \
  -q
```

It must fail because the main curl exits 0 after HTTP 201 while teardown can
leave zero/empty audit files. The existing
`test_body_captured_and_event_still_emitted` must pass pre-change as a guard.

**Focused GREEN and exact contract:**

```bash
cd ../wabbazzar-ice
.venv/bin/python -m pytest scripts/tests/test_notify_capture.py -q
bash -n scripts/notify.sh scripts/log_event.sh
```

The test module must cover HTTP 200 and 201, Signal curl rc preservation,
nonempty parseable `notify.send` and notify-data before the main process exits,
and BopBop refusal/timeout without changing the Signal result. It must assert
the two-argument body remains `title + "\n" + body`.

**Disposable user-systemd proof:**

Add `test_successful_notify_survives_disposable_systemd_teardown` in the same
test module. It must run the real `notify.sh` through
`systemd-run --user --wait --collect --unit=notify-audit-test-<unique>`, with
`SIGNAL_URL` and `BOPBOP_URL` pointing only to loopback fakes,
`WABBAZZAR_ICE_DIR` and `WABBAZZAR_NOTIFY_DIR` pointing to temp roots, and no
inherited live notification variables.

```bash
cd ../wabbazzar-ice
.venv/bin/python -m pytest \
  scripts/tests/test_notify_capture.py::test_successful_notify_survives_disposable_systemd_teardown \
  -q
systemctl --user list-units 'notify-audit-test-*' --all --no-legend
```

The test must observe `/v2/send` 200/201, main rc=0, one parseable
`notify.send`, one parseable body record, and no remaining unit/process. A
BopBop fake failure remains best-effort and cannot change rc=0.

**Full applicable Ice gate before its atomic `master` commit:**

```bash
cd ../wabbazzar-ice
.venv/bin/python -m pytest scripts/tests -q
bash -n scripts/notify.sh scripts/log_event.sh
git diff --check -- scripts/notify.sh scripts/tests/test_notify_capture.py
git status --short
```

Ice started clean and must be clean immediately after committing exactly those
paths. Do not edit the dashboard, restart `dashboard.service`, or send Signal.

### Phase 3 — Cross-repo live proof and ticket graduation (2 pts)

**Goal:** prove the complete alert path under real supervision without an
outward send, then graduate the ticket.

**Delegation: subagent — bounded independent audit brief (≤40-line return).**

> Read both phase commits and run the two focused regression surfaces without
> editing either implementation. Check same-class exit semantics in Shipyard
> and every `&` child in Ice `notify.sh`. Return ≤40 lines: commit ids; commands
> and exits; exact problem/error/HTTP/JSONL evidence; leaked unit/process
> counts; deviations/blockers. Do not send Signal, touch dashboard state,
> rewrite data, or weaken/skip a gate except the documented no-user-systemd
> skip.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

The orchestrator personally re-runs:

```bash
# Start in the Shipyard repository root.
shipyard_root="$(pwd -P)"
bats tests/overseer.bats tests/build-benign-abort.bats
bats tests/
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh

cd ../wabbazzar-ice
.venv/bin/python -m pytest scripts/tests/test_notify_capture.py -q
.venv/bin/python -m pytest scripts/tests -q
bash -n scripts/notify.sh scripts/log_event.sh

systemctl --user list-units \
  'overseer-test-*' 'notify-audit-test-*' --all --no-legend
git status --short
git -C "$shipyard_root" status --short
```

The unit list is empty. Ice is clean. Shipyard contains no ticket-scope
changes except the pending→complete move; the three unrelated pre-existing
paths remain untouched.

Graduate deterministically, verify, then commit the move alone:

```bash
cd "$shipyard_root"
# First set the opening Status to "Complete — built and verified <UTC date>"
# and finish every Ledger/DoD field.
bash scripts/ticket-lifecycle.sh --project . --graduate \
  docs/tickets/pending/overseer-signaling-integrity.md
bash scripts/ticket-lifecycle.sh --check --project .
test -f docs/tickets/complete/overseer-signaling-integrity.md
test ! -e docs/tickets/pending/overseer-signaling-integrity.md
git diff --check -- docs/tickets/complete/overseer-signaling-integrity.md
```

Use explicit adds for the old/new ticket paths only. Record both repository
commit ids and every final gate exit in the Ledger before the graduation
commit.

## Testing Strategy

- **RED is named, not inferred:** record the exact failing assertion and rc for
  each new test before implementation. Existing guards must pass pre-change.
- **No false systemd green:** `problem` and `error` each run through a normal
  disposable oneshot; do not set `SuccessExitStatus=1`.
- **No false notify green:** the fake server records the actual `/v2/send`
  request/status; tests parse both JSONL sinks after the main process has
  exited and supervisor cleanup has occurred.
- **No outward effects:** PATH stubs and loopback endpoints only. Never call
  `$QUARTET_NOTIFY_CMD`, the live Signal URL, a model, or the dashboard.
- **Cleanup is a gate:** every fake server, delayed child, and transient unit
  is terminated/collected even when an assertion fails.

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
- [ ] Ice is clean; Shipyard has no new unexplained changes and its three
  unrelated pre-existing paths are untouched.
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

- plan: Separate completed findings from assessment failures at the runner
  boundary; pin single, fleet, and transient-user-unit semantics.
- builder: subagent `signal_noise_audit`; orchestrator independently inspected
  the diff and reran every focused/full gate.
- RED command / failing assertion / exit: filtered seven new/guard Overseer
  cases; rc=1, 4 passed / 3 failed at the expected `$status -eq 0`
  assertions for a valid problem, findings-only fleet, and problem oneshot.
- pre-change error guard / exit: infrastructure error, bad invocation, and
  systemd error cases 3/3 passed, rc=0.
- focused GREEN command / count / exit:
  `bats tests/overseer.bats tests/build-benign-abort.bats` 16/16, rc=0;
  runner syntax rc=0.
- problem event + notify count + process/systemd status:
  `status=problem`, one notify-stub record, process rc=0; transient unit
  `Finished with result: success`, `code=exited/status=0`.
- error event + process/systemd status: `status=error`, process rc=1;
  transient unit `Finished with result: exit-code`,
  `code=exited/status=1`.
- full Shipyard gates / counts / exits: `bats tests/` 439/439; syntax +
  Python compile rc=0; leak/freshness/completeness/lifecycle checks rc=0.
- unrelated-path preservation proof: the concurrent Release change landed
  separately as `187e345`; Phase 1 diff contains only its two owned files plus
  this Ledger update.
- commit: `8a42948 fix(overseer): treat findings as successful runs`

### Phase 2 — Make Ice notification audits last-process durable

- plan: Make the two required audit sinks synchronous and give the optional
  BopBop child an explicit joined, timeout-bounded, non-authoritative lifetime.
- builder: subagent `signal_noise_audit`; orchestrator independently inspected
  the diff and reran focused and full Ice tests.
- RED command / failing assertion / exit: new-contract filter rc=1, five
  failures; HTTP 200/201 reached `/v2/send` and main/systemd status 0, but both
  transient-unit cases observed zero durable `notify.send` records.
- pre-change capture guard / exit: existing refused-transport capture test
  1/1, rc=0.
- focused GREEN command / count / exit:
  `.venv/bin/python -m pytest scripts/tests/test_notify_capture.py -q`
  6/6, rc=0; notifier/log-event syntax rc=0.
- HTTP requests + main exit + notify.send/body JSONL: one loopback `/v2/send`
  per case; HTTP field 200/201 with `status=ok`; main/systemd rc=0; one
  parseable event and one parseable body containing `Title\nBody`.
- BopBop failure/timeout evidence: one successful-send-only registration was
  attempted; a five-second fake was cut off by curl's existing three-second
  bound; Signal rc remained 0 and both audits persisted.
- disposable-unit and child cleanup proof:
  `list-units 'notify-audit-test-*'` empty; fake servers joined and process
  groups cleaned in test finalizers.
- full Ice gates / counts / exits: `.venv/bin/python -m pytest scripts/tests
  -q` 43/43, rc=0; syntax and scoped diff checks rc=0; clean after commit.
- commit: `47b8c85 fix: make notification audits teardown-safe`

### Phase 3 — Cross-repo live proof and ticket graduation

- plan:
- builder:
- independent audit verdict:
- cross-repo focused/full gates / counts / exits:
- final transient unit/process query:
- final Shipyard status (including preserved unrelated paths):
- final Ice status:
- Shipyard commit:
- Ice commit:
- status header + lifecycle check / exit:
- graduation commit:

Run with: `execute-ticket docs/tickets/pending/overseer-signaling-integrity.md`.
There are no open decisions; the parent explicitly owns the transition from
polish to execution.
