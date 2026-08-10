# Make the Shipyard proctor battery runner-owned

- **Created:** 2026-08-10
- **Owner:** wabbazzar
- **Status:** Pending
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 5 (two phases: 3 · 2)
- **Refs:** approved Daily Dispatch item `mentat:shipyard:9db7c9ba`;
  `agents/release/runner.sh:88-114`, `agents/release/runner.sh:244-266`,
  `agents/release/runner.sh:365-473`, `agents/release/runner.sh:528-535`,
  `.agents/config.toml:41-50`, `.agents/release.md:11-22`,
  `tests/release-blocking-gate.bats:112-351`

## Summary

Move Shipyard's long daily `bats tests/` battery from model-owned execution to
the release runner's existing synchronous `[release.blocking_gate]` mechanism.
The daily proctor must not publish or exit until the battery finishes and the
runner has reconciled its result into `result.json`; the existing fail-closed
outer exit invariant remains mandatory.

## Objective

For Shipyard daily release runs, the model performs the short judgment/check
surface but never invokes, backgrounds, or polls `bats tests/`. The runner then
executes that exact command once in the foreground with a bounded timeout,
waits for completion, writes a non-colliding `batsGate` result into the public
release JSON, and makes JSON, terminal event, and process exit agree. Exit zero
is possible only after a nonempty valid result exists and the runner-owned
Bats gate completed successfully.

## Problem / background

### Captured reproduction — 2026-08-08 daily Shipyard proctor

The real one-shot release transcript launched `bats tests/ | tail -40`. After
120 seconds the harness reported:

```text
Command did not complete within its 120s timeout and was moved to the background
```

The Bats processes were still alive and no TAP verdict existed. The model then
ended its one-shot turn with:

```text
I'll wait for the background bats task and monitor to notify me when complete instead of polling further.
```

No model-authored release result was written. The runner correctly synthesized
`pass:false` with `proctor claude run exited (0) without writing result.json`,
emitted `job.end status=fail exit_code=1`, and systemd recorded failure. The
`0` in the incident summary was the model transport exit, not the final proctor
exit.

### Violated observable contract

The wrapper's post-hoc safety contract worked: a missing/negative result cannot
escape as outer exit zero (`agents/release/runner.sh:331-361,528-535`). The
unmet contract is prevention and completion: the canonical daily battery is
still model-owned in `.agents/release.md:11-22`, so a one-shot tool ceiling can
background it and end the turn before a verdict exists. An unsuccessful
scheduled release run is correctly detected, but the release work does not get
done.

### Rival causes

| Candidate | Expected if true | Actual | Verdict |
|---|---|---|---|
| Outer runner lacks fail-close | A clean model transport with no/negative result exits the proctor zero. | The Aug 8 event and focused fixtures show outer exit 1; the guard entered before this incident. | Ruled out. Preserve it as a regression guard. |
| Bats failed | Completed TAP is nonzero and the model writes a failed result. | The command was still running, its piped output remained empty, and no Bats verdict existed. | Ruled out. |
| systemd/model timeout or external kill | Journal or transport reports timeout/signal near the configured deadline. | The turn ended normally after about 188 seconds; systemd and model deadlines were still far away. | Ruled out. |
| Shipyard has no synchronous runner mechanism | No validated foreground gate exists, or it cannot reconcile results/exits. | `release.blocking_gate` already validates, runs under `timeout`, withholds publication, and reconciles JSON/event/exit; 23 focused tests pass. | Ruled out. |
| Shipyard never activated the runner-owned mechanism | `--check-config` reports `blocking_gate:null` and the project prompt tells the model to run Bats. | Both are true on current main. | Ruled in. |

## Root cause and coverage gap

The defect is in Shipyard's project configuration/prompt boundary, not missing
core runner machinery. Runner-owned blocking gates shipped in commit `187e345`
before this incident, but `.agents/config.toml:41-50` kept `bats tests/` only as
ordinary `test_cmd` and never added `[release.blocking_gate]`. The project
prompt therefore continued assigning the long command to the model and relied
on a prose prohibition against background work.

The same class has appeared in other projects when long gates crossed the
one-shot tool ceiling, but this approved item is specifically Shipyard's daily
proctor. Existing `tests/release-stall-retry.bats` proves post-hoc no-result
failure and `tests/release-blocking-gate.bats` proves the generic opt-in
mechanism. Nothing pins that Shipyard's tracked config actually opts its long
daily battery into that mechanism or that its project prompt no longer assigns
Bats to the model. That project-adoption guard is the missing coverage.

## Decisions

### Locked

| Decision | Locked result |
|---|---|
| Mechanism | Use the existing `[release.blocking_gate]`; do not add process discovery, PID joining, another runner primitive, or more prompt-only admonitions. |
| Command | `bats tests/`, exactly matching `[release].test_cmd` so post-merge keeps its existing deterministic path. |
| Modes | `daily` only. Hook behavior remains unchanged; post-merge never invokes the model and continues to run `test_cmd`/`typecheck` directly. |
| Timeout | 900 seconds: bounded well below the service/model ceiling and above the measured 808-case baseline. Preserve exit 124 on timeout. |
| Result key | `batsGate`, avoiding collision with the project prompt's existing model-authored `bats` count object. The model must never write `batsGate`. |
| Result publication | The public result and terminal event remain private until the foreground Bats command completes and the runner atomically reconciles `{status,pass,exitCode}`. |
| Exit invariant | Preserve the current rule: a missing/invalid/negative final result with transport zero becomes outer exit 1; genuine nonzero gate/model codes remain exact. |
| Live proof | The approved acceptance authorizes one controlled `shipyard-proctor.service` start after hermetic gates and a clean tree; no retry loop or repeated paid run is authorized. |

### Open decisions with defaults

None.

### User-decision class

None. The single controlled live proctor invocation is part of the explicitly
approved acceptance. Publication remains PR-only and merge remains human-only
under `can_merge=false`.

## Technical requirements

- Add this exact table beneath the existing `[release]` config without changing
  `test_cmd` or `typecheck`:

  ```toml
  [release.blocking_gate]
  command = "bats tests/"
  timeout_sec = 900
  modes = ["daily"]
  result_key = "batsGate"
  ```

- Update `.agents/release.md` so Step 1 distinguishes daily runner-owned Bats
  from post-merge `test_cmd`, tells the model to obey
  `RUN CONTEXT.runner_owned_gate`, and removes the stale “~138 cases, ~17s”
  claim. Keep the remaining short syntax/leak/deck checks model-owned.
- Update the project result-field section: `bats` is legacy/model-owned only
  when no matching runner gate exists; `batsGate` is runner-owned and the model
  must omit it. Do not change the generic result schema or core runner.
- Add a failing-first repository guard in a narrowly named Bats file or
  `tests/release-blocking-gate.bats` that proves current Shipyard
  `--check-config` reports a daily blocking gate with the exact command,
  timeout, and non-colliding key while retaining `test_cmd` for post-merge.
- The guard must also pin one single-line project-prompt phrase stating Bats is
  runner-owned in daily mode. Avoid a regex that crosses Markdown wrapping.
- Keep all existing generic blocking-gate, stall, incomplete, harness, and
  post-merge tests green. Do not change runner retry/backoff, model invocation,
  service timeout, or notification behavior.

## Implementation plan

### Phase 1 — activate and guard the runner-owned battery (3 pts)

- Add the project-adoption Bats guard and show it RED against pre-change
  tracked config/prompt.
- Add the blocking-gate table and rewrite only the project-specific Bats/prompt
  contract.
- Prove `--check-config` is read-only and reports both the exact blocking gate
  and unchanged `test_cmd`/`typecheck`.
- Run the focused generic gate/stall tests plus syntax, leak, and diff gates.

Delegation: subagent — own `.agents/config.toml`, `.agents/release.md`, and the
focused project-adoption fixture; return the exact RED, GREEN result JSON, and
focused gate counts in no more than 40 lines.

### Phase 2 — full and controlled live proof (2 pts)

- Run the complete repository verification surface from a clean committed
  tree.
- Capture the pre-run result timestamp/hash and service state, start
  `shipyard-proctor.service` exactly once, and wait for the unit to finish.
- Prove journal ordering `blocking_gate start` → Bats completion →
  `blocking_gate end`; inspect the new result JSON for `batsGate.status=completed`,
  its pass/exit code, and consistent top-level pass.
- Prove the terminal `job.end` exit/status agrees with the JSON. If any real
  check fails, record it honestly; do not weaken or rerun in a loop.
- Publish the exact verified head through a PR, require green CI, and stop for
  the human merge stamp.

Delegation: subagent — cold-review the Phase 1 diff and the captured live
artifacts; return drift findings and exact result/journal/event evidence in no
more than 40 lines. The orchestrator retains the one live start, full gates,
notification, publication, and commit authority.

## Testing strategy

- Capture RED with the new project-adoption guard before editing config/prompt;
  the expected pre-change failure is `blocking_gate:null` and absent
  runner-owned daily wording.
- Use the existing hermetic generic matrix in
  `tests/release-blocking-gate.bats` and no-result/exit matrix in
  `tests/release-stall-retry.bats`; no fixture may invoke a real model,
  network, GitHub, service, or notification.
- Assert config output, prompt ownership, publication ordering, result JSON,
  event status, and process exit—not only that TOML parses.
- Run `bats tests/`, `bash scripts/leak-check.sh`, and
  `bash scripts/check-deck-fresh.sh`, plus applicable syntax, lifecycle,
  delegation, and diff gates.

## Definition of Done

- [ ] A failing-first Bats guard proves Shipyard lacked a configured runner-owned daily Bats gate before this fix.
- [ ] Shipyard `--check-config` reports `command="bats tests/"`, `timeout_sec=900`, `modes=["daily"]`, and `result_key="batsGate"` while retaining its existing `test_cmd` and `typecheck`.
- [ ] The project prompt no longer assigns daily Bats execution/background monitoring to the model and preserves post-merge behavior.
- [ ] Generic configured/absent/malformed blocking-gate behavior and no-result fail-close behavior remain green.
- [ ] One controlled proctor run waits for the foreground battery, produces a valid result with completed `batsGate`, and makes JSON, event, systemd, and process status agree.
- [ ] Exit zero is observed only with a nonempty valid result and successful completed `batsGate`; a failed/timeout gate retains its nonzero code.
- [ ] No retry/backoff, timeout policy outside the blocking-gate table, model/provider, notification, or core runner behavior changes.
- [ ] Focused tests, full Bats, shell syntax, leak, deck freshness/completeness/render, lifecycle, delegation, and diff gates pass.
- [ ] The exact verified head is published through a green PR; the builder does not merge it.

## Boundaries

### Always

- Preserve the current outer fail-close guard and exact nonzero exit codes.
- Keep the Bats command runner-owned, synchronous, bounded, and visible in the
  final result/event evidence.

### Ask first

- Enabling runner-owned gates for hook mode or for another project.
- Changing the 900-second timeout after measuring a legitimate clean run that
  exceeds it.

### Never

- Discover, wait for, or kill model-created background PIDs.
- Add a new top-level dependency, retry/backoff path, alternate release runner,
  or prompt-only workaround in place of the existing blocking gate.

## Dependencies

- Existing runner-owned blocking-gate implementation and test matrix from
  commit `187e345`.
- Existing no-result outer fail-close guard from commit `5c05ec9`.
- Human approval recorded for `mentat:shipyard:9db7c9ba`.

## Risks and mitigations

- **Duplicate Bats execution:** make daily ownership explicit in both config
  and prompt, then inspect the model prompt fixture/captured live log for one
  runner-owned invocation.
- **Result-key collision:** use `batsGate`; retain a focused assertion that the
  model does not write that field.
- **Hanging the unit:** bound the command at 900 seconds and preserve exit 124;
  the service/model ceilings remain unchanged.
- **False promotion after unrelated model failure:** retain the existing
  independent-failure matrix and require top-level/event/exit agreement.
- **Paid live rerun loop:** authorize exactly one controlled start; a genuine
  failure is evidence, not permission to repeat until green.

## Out of scope

- Any edit to `agents/release/runner.sh`, `agents/lib/spawn.sh`, systemd unit
  generation, stall retries, backoff, or provider/model selection.
- Activating the blocking gate for hook mode or other installed projects.
- Changing the canonical Bats suite, muting failures, or reducing coverage to
  fit the one-shot tool ceiling.

## Ledger

- 2026-08-10 — draft created from approved Daily Dispatch item
  `mentat:shipyard:9db7c9ba`. Root personally confirmed the Aug 8 transcript
  signature and two focused no-result guards. Three independent read-only rival
  probes ruled out Bats failure, systemd timeout/external kill, and missing
  outer fail-close; they ruled in absent Shipyard blocking-gate adoption. No
  runtime code, config, service, model, notification, or remote state changed
  during intake.

---

Draft ready for `polish-ticket`.
