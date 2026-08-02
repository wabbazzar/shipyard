# Release runner incomplete-exit reconciliation

- **Created:** 2026-08-02
- **Owner:** wabbazzar
- **Status:** Complete — built and verified 2026-08-02 CDT
- **Priority:** critical
- **Type:** bugfix
- **Estimated Points:** 3 (two phases: 2 · 1)
- **Refs:** `agents/release/runner.sh`,
  `agents/lib/release-verdict.sh`, `tests/release-stall-retry.bats`,
  `tests/release-blocking-gate.bats`, `tests/release-incomplete-notify.bats`

## Summary

Make every model-backed release invocation return a nonzero shell status when
its final reconciled verdict is `pass:false`, including the
`run-in-progress`/incomplete case. Preserve genuine harness and runner-owned
gate exit codes, successful and partial-run semantics, all three supported
model harnesses, and the existing distinction between an unfinished review and
an actionable gate failure.

## Objective

A caller must be able to trust the release runner's outer process status as a
faithful terminal summary of the reconciled JSON verdict. A model process that
exits zero after leaving `pass:false` or `run-in-progress` may never make the
release command appear successful.

## Problem / Background

Aurora's live hook release run reproduced a false-success boundary:

```text
agents/release/runner.sh --project <aurora-checkout> --mode hook
outer shell status: 0
result: {"pass":false,"mode":"hook","errors":["run-in-progress"],"incomplete":true}
log: [aurora-proctor] done pass=false exit=0
```

The model started the long canonical test suite, then ended its one-shot turn
while that background command was still running. `spawn_model` correctly
returned zero because the model turn itself completed. The runner subsequently
classified the result as `JOB_STATUS=fail` and `INCOMPLETE=1`, but retained
`FINAL_EXIT="$EXIT"` from the successful harness transport and ultimately
exited zero.

This violates one observable contract: **a final `pass:false` release verdict
must produce a nonzero outer runner status**. `job.end`, notifications, and the
result JSON already describe the run as unsuccessful or incomplete; only the
shell boundary disagrees.

### Root cause and ruled-out rivals

- **Root cause:** `agents/release/runner.sh` initializes `FINAL_EXIT` from the
  harness transport status and never reconciles a zero value after parsing and
  possibly overriding the final verdict.
- **Trigger, not root cause:** the model ignored the foreground-only release
  instruction and backgrounded the long command. One-shot harnesses can still
  legitimately end with a written negative verdict, so the runner must enforce
  its own terminal contract.
- **Not the cause:** `agents/lib/post-run.sh` consumes the already-derived job
  state; it does not choose the runner's final exit code.
- **Configuration exposure:** Aurora does not yet use
  `[release.blocking_gate]`, so its long canonical suite remained model-owned.
  Runner-owned blocking gates are the existing synchronous mechanism; this
  ticket must preserve their exact exit codes rather than guessing at child
  PIDs or joining model-created background work.

### Coverage gap

Existing tests assert `release_incomplete` classification, JSON fields,
notification class, and `job.end` state, but the unconfigured model-backed
runner cases do not pin the outer Bats `$status`. That allowed a contradictory
zero shell status to ship. Blocking-gate tests do pin exact exit codes and must
remain green.

## Confirmed Decisions

| Decision | State | Rationale |
|---|---|---|
| `pass:false` plus transport exit zero maps to runner exit `1` | locked | `1` is the generic failed verdict; `2` and `3` retain their established invocation/config and deliberate-no-op meanings. |
| Preserve any genuine nonzero harness or blocking-gate code | locked | Exit codes are load-bearing and already convey more specific failure information. |
| Do not find, wait for, or kill model-created background PIDs | locked | The runner has no reliable ownership proof; the written terminal verdict is the safe boundary. |
| Keep incomplete notifications routine | locked | An unfinished review is not proof that the project gates failed, even though it must block callers. |
| Keep release harness-agnostic | locked | Claude, Codex, and Hermes all use the same reconciler and must retain supported paths. |
| Long deterministic project gates belong in `release.blocking_gate` | locked | The runner-owned foreground command is the supported synchronous contract. Project adoption is separate from this fleet-core fix. |

There are no open user-decision-class items.

## Verified Polishing Baseline — 2026-08-02 CDT

- `bats tests/release-incomplete-notify.bats
  tests/release-stall-retry.bats tests/release-blocking-gate.bats` passed
  24/24 in 4.57 seconds.
- Aurora's live hook command reproduced the defect before this ticket:
  `tmp/aurora-proctor-result.json` had `pass:false`, `incomplete:true`, and
  `errors:["run-in-progress"]`; `tmp/aurora-proctor-last-run.log` ended
  `done pass=false exit=0`; the outer shell status was zero.
- `agents/release/runner.sh --project <aurora-checkout> --check-config`
  reported `blocking_gate:null`; its deterministic commands are the Python
  and wireframe test suites plus a Python byte-compile.
- No Shipyard timers were visible in this interactive user's
  `systemctl --user list-timers --all` output, and
  `$QUARTET_EVENTS_DIR` was unavailable in the interactive shell. The
  hermetic fixture event stream is therefore the required event proof; any
  live phase reads the configured project's own result and log directly.
- Bats 1.10.0, jq, Git, and the three harness dispatch implementations are
  present. Hermetic tests must use PATH stubs and may not call a network or a
  real model.
- Shipyard's `main` checkout was at `07f531d` when polished. Because
  `[medic] can_merge=false` and this runner is fleet-live from the canonical
  checkout, execution uses branch
  `bugfix/release-runner-incomplete-exit`, pushes it, opens a pull request,
  and does not self-merge. Preserve the unrelated existing
  `docs/styles.css` worktree modification.

## Technical Requirements

### 1. Terminal exit reconciliation

- After all model-result, runner-owned blocking-gate, incomplete, and
  `verify_gate` reconciliation is complete, enforce:
  - if final `PASS` is not `true` and `FINAL_EXIT` is zero, set
    `FINAL_EXIT=1`;
  - otherwise preserve `FINAL_EXIT` byte-for-byte.
- The reconciled value must be identical in:
  - the outer shell status;
  - `job.end.exit_code`;
  - the terminal `done ... exit=` log line;
  - the fallback notification summary when used.
- Preserve result JSON classification and content except for changes already
  made by existing reconciliation paths.
- Preserve `JOB_STATUS=fail` for `pass:false`, `JOB_STATUS=ok` for a clean
  `pass:true`/zero run, and `JOB_STATUS=partial` for a written `pass:true` with
  a nonzero harness exit.
- Preserve exact blocking-gate failure/timeout codes and exact nonzero harness
  codes.
- Do not add a compatibility flag. This corrects the already-declared
  relationship between a final negative verdict and a failed `job.end`; it is
  not an additive capability whose broken path should remain the unset
  default. Config-gated-additivity evidence here is the unchanged clean-pass,
  partial, exact nonzero, and blocking-gate behavior.

### 2. Hermetic cross-harness regression

- Add a no-network/no-model Bats regression that writes a
  `pass:false`, `incomplete:true`, `run-in-progress` sentinel and makes the
  selected harness transport exit zero.
- Assert outer status `1`, result `pass:false` and `incomplete:true`,
  `job.end.status=fail`, `job.end.exit_code=1`, routine/incomplete
  notification classification, terminal log `exit=1`, exactly one model
  attempt, and no stall retry after a written verdict.
- Exercise the generic path through Claude, Codex, and Hermes stubs, or prove
  with a shared parameterized fixture that the reconciler receives identical
  normalized `SPAWN_RC=0` and result bytes from each supported harness.
- Close the neighboring contradiction for an ordinary written `pass:false`
  verdict with transport exit zero: outer status and `job.end.exit_code` are
  `1`, with actionable gate-failure classification.
- Pin unchanged boundaries:
  - clean written `pass:true` plus transport exit zero returns zero;
  - written `pass:true` plus harness exit `9` returns `9` and remains partial;
  - written `pass:false` plus harness exit `7` returns `7`;
  - blocking-gate exit `7` and timeout `124` remain exact;
  - successful keyed blocking gate returns zero when it legitimately resolves
    its sole model `run-in-progress` placeholder.

## Phased Execution Plan

### Phase 1 — Red regression and runner reconciliation (2 points)

**Delegation:** subagent — in the Shipyard checkout on
`bugfix/release-runner-incomplete-exit`, own only
`tests/release-stall-retry.bats` (or one new narrowly named release Bats file)
and `agents/release/runner.sh`. Reuse `tests/helpers.bash`,
`make_fixture_project`, PATH stubs, `run_runner`, and the existing release
event helpers. First add a real runner case whose model writes
`pass:false,incomplete:true,errors:["run-in-progress"]` and exits zero; return
the focused pre-code failure showing Bats `$status=0`. Then add the minimal
final-exit reconciliation after `verify_gate`, and cover ordinary negative,
clean positive, partial/nonzero, and all supported harness boundaries. Do not
touch project config, notifications, model prompts, `docs/styles.css`, or
background PIDs. Return in at most 40 lines: files changed; commands run plus
exit codes; exact test counts/status/log/event evidence; blockers.

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

1. Add the sentinel, ordinary-failure, success, partial, and nonzero-preserving
   assertions around the real release runner using existing fixture helpers.
2. Run the focused new case against the pre-change runner and capture its
   expected failure (`$status` is zero instead of one).
3. Add the smallest post-reconciliation `FINAL_EXIT` rule after
   `verify_gate`, before summaries/events/exit consume it.
4. Run the focused release suites and syntax sweep.

**Gate classes:** shell scripts, Bats suite, model-invocation caps,
config-gated additivity, public-repo hygiene, delegation contract.

**Exact verification:**

```bash
bats tests/release-incomplete-notify.bats \
  tests/release-stall-retry.bats tests/release-blocking-gate.bats
bash -n agents/release/runner.sh
bats tests/token-caps.bats tests/harness-spawn.bats
git add -N <new-test-file-if-any>
bash scripts/leak-check.sh
python3 scripts/delegation-report.py
```

**Phase acceptance:** the captured sentinel reproduction returns one and the
named outer-status coverage gap is closed without changing exact pre-existing
nonzero codes. The fixture's terminal result has `pass:false` and
`incomplete:true`; `job.end` has `status:"fail",exit_code:1`; the last runner
log line ends `pass=false exit=1`; and the notification decision remains
routine with cause `incomplete`.

### Phase 2 — Fleet regression and live Aurora proof (1 point)

**Delegation:** inline (gate commands are orchestrator-owned evidence).

1. Run the complete Shipyard gate surface.
2. Run `agents/release/runner.sh --check-config` against Aurora and inspect the
   effective harness/gate configuration without changing Aurora config.
3. Run a live Aurora hook release. If it again finishes with an incomplete
   sentinel, prove that the command now exits one and all JSON/event/log
   surfaces agree; if it completes normally, additionally run the exact
   hermetic sentinel fixture and record both pieces of evidence.
4. Confirm no Claude-, Codex-, or Hermes-specific release pathway was retired
   or made stale.

**Gate classes:** shell scripts, Bats suite, public-repo hygiene, delegation
contract.

**Exact verification:**

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
agents/release/runner.sh --project <aurora-checkout> --check-config
agents/release/runner.sh --project <aurora-checkout> --mode hook
python3 scripts/delegation-report.py
```

The live hook command is intentionally foreground and may invoke the configured
model. Capture its shell status immediately; then read
`<aurora-checkout>/tmp/aurora-proctor-result.json` and
`<aurora-checkout>/tmp/aurora-proctor-last-run.log`. Never substitute a later
file read for the command's actual status. Use `$QUARTET_NOTIFY_CMD` only
through the runner's existing notification path. Do not add direct Signal
calls.

**Phase acceptance:** the full suite is green and a live installed runner plus
the hermetic regression demonstrate that release callers can no longer receive
a false zero from a negative terminal verdict. `git status --short` contains
only the ticket's owned files plus the preserved pre-existing
`docs/styles.css`; the phase commit is pushed and its pull request is open,
but not self-merged.

## Definition of Done

- [x] The captured `run-in-progress` reproduction returns nonzero.
- [x] Every final `pass:false` plus zero transport exit returns exactly `1`.
- [x] Genuine nonzero harness and blocking-gate exit codes are preserved.
- [x] JSON, `job.end`, terminal log, fallback summary, and outer status agree.
- [x] Incomplete remains routine/non-actionable while blocking the caller.
- [x] Claude, Codex, and Hermes remain supported by the same generic contract.
- [x] The named outer-status coverage gap is closed with hermetic Bats tests.
- [x] Focused release suites, full `bats tests/`, syntax, leak, deck freshness,
      and deck completeness gates pass.
- [x] Aurora's effective release configuration is inspected and a live
      post-fix hook result is recorded.
- [x] Ledger records per-phase builder, gates, evidence, commit, and result.

## Out of Scope

- Killing, joining, or adopting arbitrary model-created background processes.
- Changing project test commands or solver/runtime behavior.
- Adding an Aurora `[release.blocking_gate]` entry in this Shipyard commit.
- Replacing one supported reviewer harness with another.
- Dual-model pull-request review or GitHub comment conversations; that remains
  future additive work.

## Ledger

| Phase | Builder | Gates / Evidence | Commit | Result |
|---|---|---|---|---|
| 1 | subagent (1 agent) | Pre-code real-runner sentinel failed with `expected fail-closed outer status 1, observed 0`. Post-fix release suites passed 33/33 and token/harness suites passed 34/34; Claude, Codex, and Hermes each produced outer/job exit 1 from `pass:false` + incomplete + transport 0 with one attempt and no retry. `pass:true/0`, `pass:true/9`, `pass:false/7`, blocking-gate 7/124, syntax, diff, leak, and delegation gates passed. Independently rerun by orchestrator. | `d97065c` | complete |
| 2 | orchestrator (inline: final gates and live installed-runner proof) | Final `bats tests/` passed 726/726. Syntax, Python compile, leak, deck freshness/completeness, diff, lifecycle, and delegation gates passed. A concurrent scheduled reviewer exposed and fixed one ambient-environment test leak in `8b94e8f`, then independently passed the same 726-test fleet surface. The hermetic matrix kept Claude, Codex, and Hermes on the same generic path; Aurora config inspection reported its active Codex shoulder configuration and `blocking_gate:null`. Its scheduled daily run and the controlled foreground hook both left `pass:false,incomplete:true,errors:["run-in-progress"]`; the installed fixed runner returned `1`, logged `done pass=false exit=1`, and systemd recorded the daily unit as failed with status 1. The first complete-suite attempt's timing-sensitive stop-poll case passed alone; after correcting the medic fixture's stale exit-zero expectation, the complete suite passed cleanly. | `8b94e8f` + this commit | complete |

Execute with `execute-ticket
docs/tickets/pending/release-runner-incomplete-exit.md`.
