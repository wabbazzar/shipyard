# Make the Shipyard proctor battery runner-owned

- **Created:** 2026-08-10
- **Owner:** wabbazzar
- **Status:** Pending — polished; no open decisions
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

**Auto-gate: PROCEED.**

## Orchestration protocol

The builder is the orchestrator. Delegate each implementation/review slice,
keep every return at or below 40 lines, and personally rerun every named gate
before every commit. Work only in this canonical checkout on local `main`, in
small verified commits; do not create or switch to a local branch/worktree.
Before each edit and commit, run `git status --short --branch` and
`git log --oneline -3`. If another session changed the head or overlapping
files, stop staging and reconcile without reset, rebase, force-push, or lost
history. Scope every `git add` to this ticket's files; never use `git add -A`.

This ticket and the separately approved weekly-limit medic ticket are already
serialized on the same canonical local `main`. Publish their exact cumulative
head through one delivery branch and one PR; retain separate tickets, commits,
acceptance evidence, and Ledger rows. The builder may not merge the PR because
`[medic].can_merge=false`.

For every delegated slice:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

## Verified polishing baseline — 2026-08-10 CDT

| Surface | Evidence | Consequence |
|---|---|---|
| Reproduction | The Aug 8 transcript records the 120-second tool ceiling moving Bats to the background and the model ending its one-shot turn without a verdict. The runner synthesized a negative result and emitted outer exit 1. | Repair ownership/completion; preserve the working fail-close invariant and describe transport exit 0 accurately. |
| Current config | `agents/release/runner.sh --project . --check-config` reports the expected `test_cmd` and `typecheck`, but `blocking_gate:null`. Shipyard's `.agents/` install state is intentionally ignored. | Activate and prove the machine-local project opt-in; no core runner edit or claim of a tracked config diff is justified. |
| Focused guards | `bats tests/release-blocking-gate.bats tests/release-stall-retry.bats` passed 23/23. | Preserve generic configured/unset/malformed behavior and outer no-result failure while adding a Shipyard adoption guard. |
| Full baseline | The pre-implementation canonical suite passed 808/808; syntax, Python compile, leak, deck freshness/completeness/render, lifecycle, delegation, and diff gates passed. | Any regression belongs to this delivery unless independently evidenced. |
| Live unit | `shipyard-proctor.service` is inactive, executes the canonical checkout's release runner, and has a 1h5m start timeout. | After a clean committed hermetic baseline, one foreground `systemctl --user start` is the real completion proof; never start it twice to chase green. |
| Capability | Shipyard keeps `allow_no_ci=false` and `can_merge=false`. | Require green CI on the cumulative delivery PR and stop for the human stamp. |

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
- Capture a failing-first local adoption assertion against the current
  `--check-config` output: before the config edit it must fail specifically
  because `blocking_gate:null`; after the edit it must prove the exact command,
  timeout, mode, result key, and retained `test_cmd`/`typecheck`.
- Pin one single-line project-prompt phrase stating Bats is runner-owned in
  daily mode. `.agents/config.toml` and `.agents/release.md` are intentionally
  ignored project install state, so neither may be represented as a tracked PR
  diff or a fresh-clone CI guard. Existing tracked generic Bats tests remain the
  portable regression coverage; the controlled live run is the project-
  adoption proof.
- Add the existing README safety/config table's missing
  `[release.blocking_gate]` row so operators can route long deterministic gates
  to the synchronous runner-owned mechanism without implying it is universal.
- Keep all existing generic blocking-gate, stall, incomplete, harness, and
  post-merge tests green. Do not change runner retry/backoff, model invocation,
  service timeout, or notification behavior.

## Implementation plan

### Phase 1 — activate and prove the runner-owned battery config (3 pts)

- Run the exact `jq -e` adoption assertion first and show it RED against the
  pre-change local config (`blocking_gate:null`).
- Add the blocking-gate table and rewrite only the project-specific Bats/prompt
  contract.
- Add the generic README safety/config row; do not present the local Shipyard
  opt-in as a tracked project file.
- Prove `--check-config` is read-only and reports both the exact blocking gate
  and unchanged `test_cmd`/`typecheck`.
- Run the focused generic gate/stall tests plus syntax, leak, and diff gates.

Delegation: subagent — own `.agents/config.toml`, `.agents/release.md`, and the
existing README safety/config table. First run the named local `jq -e`
assertion against unchanged config to capture the real RED. Do not add a
project-adoption Bats fixture that would depend on ignored install state; do not
edit the core release runner, generic role, service units, retry/backoff, medic
files, or remote state. Return no more than 40 lines: files changed; exact RED
and GREEN commands with exit codes/counts; `--check-config` JSON; prompt and
README phrases; ignored/tracked scope; blockers. Apply the anti-cheating clause
in the Orchestration protocol verbatim.

**Phase 1 verification surface:**

```bash
git status --short --branch
git log --oneline -3
bash -n agents/release/runner.sh
bats tests/release-blocking-gate.bats tests/release-stall-retry.bats
agents/release/runner.sh --project . --check-config | jq -e '
  .test_cmd == "bats tests/" and
  (.typecheck | test("bash -n install.sh")) and
  .blocking_gate.command == "bats tests/" and
  .blocking_gate.timeout_sec == 900 and
  .blocking_gate.modes == ["daily"] and
  .blocking_gate.result_key == "batsGate"'
grep -F 'Daily Bats is runner-owned' .agents/release.md
grep -F '[release.blocking_gate]' README.md
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
git diff --check
python3 scripts/delegation-report.py
```

Observable Phase 1 DoD: the Ledger records the pre-change
`blocking_gate:null` assertion RED, then the exact configured JSON and a focused
23-case green matrix; no core runner, service-unit, or new project-specific
test diff exists. Git status shows only the README/ticket as tracked delivery
changes; the local config/prompt remain installed but ignored.

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
notification, publication, and commit authority. Apply the anti-cheating clause
in the Orchestration protocol verbatim.

**Phase 2 verification surface before the one live start:**

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
find ../* -path '*/.claude/skills/*' -type l -lname '*worktrees*' -print 2>/dev/null | wc -l  # must print 0
```

Commit the hermetic Phase 1 result and make the worktree clean before the live
proof. The orchestrator records the old result file's existence, byte count,
mtime, and checksum without deleting or truncating it; records the unit state;
then invokes exactly once:

```bash
systemctl --user start shipyard-proctor.service
```

That foreground command must be allowed to block. After it returns, record its
actual exit; `systemctl --user show shipyard-proctor.service` result/status;
the bounded journal from the captured start timestamp; the new public result's
valid JSON, nonzero bytes, mtime/checksum, top-level `pass`, and
`.batsGate == {"status":"completed","pass":true,"exitCode":0}`; and the
matching terminal `job.end` event from the configured event directory. A real
failure is written to the Ledger and stops publication until the failure is
routed; it does not authorize another live start.

After all local acceptance evidence is green, publish the exact cumulative
head without switching the checkout:

```bash
git fetch origin main
git status --short --branch
git log --oneline origin/main..HEAD
git push origin HEAD:refs/heads/bugfix/shipyard-proctor-runner-owned-battery
gh pr create --repo wabbazzar/shipyard --base main \
  --head bugfix/shipyard-proctor-runner-owned-battery \
  --title "Make Shipyard proctor battery runner-owned" \
  --body-file <prepared-body>
gh pr checks <number> --repo wabbazzar/shipyard --watch --interval 10
```

Do not merge. When every required check is green, send exactly one PR-ready
owner alert through the configured `$QUARTET_NOTIFY_CMD`, record its outcome,
and stop for the human merge stamp. GitHub unavailability is an external block,
not permission to treat CI as green.

## Testing strategy

- Capture RED with the exact local `jq -e` adoption assertion before editing
  config/prompt; the expected pre-change failure is `blocking_gate:null`.
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

- [x] A failing-first local config assertion records that Shipyard lacked a configured runner-owned daily Bats gate before this fix.
- [x] Shipyard `--check-config` reports `command="bats tests/"`, `timeout_sec=900`, `modes=["daily"]`, and `result_key="batsGate"` while retaining its existing `test_cmd` and `typecheck`.
- [x] The project prompt no longer assigns daily Bats execution/background monitoring to the model and preserves post-merge behavior.
- [x] Generic configured/absent/malformed blocking-gate behavior and no-result fail-close behavior remain green.
- [x] One controlled proctor run waits for the foreground battery, produces a valid result with completed `batsGate`, and makes JSON, event, systemd, and process status agree.
- [x] Exit zero is observed only with a nonempty valid result and successful completed `batsGate`; a failed/timeout gate retains its nonzero code.
- [x] No retry/backoff, timeout policy outside the blocking-gate table, model/provider, notification, or core runner behavior changes.
- [x] Focused tests, full Bats, shell syntax, leak, deck freshness/completeness/render, lifecycle, delegation, and diff gates pass.
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
- 2026-08-10 — polished against the real transcript/event distinction, current
  config and release prompt, existing runner-owned gate implementation, 23/23
  focused guards, 808/808 full-suite baseline, live service wiring, and
  project gates/capabilities. Exact RED/GREEN and controlled-live surfaces,
  bounded delegation briefs, cumulative PR publication, and the one-start rule
  are locked. No runtime code, config, service, model, notification, or remote
  state changed while polishing.
- 2026-08-10 — execution routing correction: `builder: inline (single-file
  edit in an already-read ticket)`. Shipyard's `.agents/` project state is
  intentionally ignored, so a tracked project-adoption Bats guard would fail
  in a fresh CI clone and misroute a project gate into portable core. The
  failing-first evidence is therefore the exact local `--check-config`
  assertion; existing 23-case generic Bats coverage remains portable, the
  controlled service run proves local adoption, and README gains the portable
  operator-facing config contract. No runtime, service, model, notification,
  or remote action occurred during this correction.
- 2026-08-10 — Phase 1 plan: `builder: subagent (1 agent)`. The builder owns
  only the installed Shipyard release config/prompt and the tracked README
  config row; root retains all focused/full verification, Ledger, staging,
  commit, controlled live start, publication, notification, and merge-stop
  authority. The concurrent scribe runner/test drop is out of scope and must be
  preserved untouched.
- 2026-08-10 — Phase 1 spec correction: `builder: inline (single-file edit in
  an already-read ticket)`. The builder correctly found that `--check-config`
  exposes `test_cmd`, `typecheck`, and `blocking_gate` at the JSON top level;
  the ticket's nested `.release.*` predicate could never pass. The verification
  command now targets the existing public output contract. No implementation,
  gate strength, or acceptance behavior changed.
- 2026-08-10 — Phase 1 implementation: `builder: subagent (1 agent)`. RED
  recorded a valid flat `--check-config` response with `blocking_gate:null`.
  Shipyard's ignored config now retains the approved medic opt-in and adds the
  exact daily `batsGate` table; the ignored release prompt makes Daily Bats
  runner-owned, forbids model invoke/background/poll, and preserves hook and
  post-merge paths. README adds the portable default-unset config contract.
  Root independently passed the corrected exact config predicate, prompt and
  README assertions, syntax, the 23/23 generic blocking/stall matrix, TOML
  semantic assertions, leak, deck freshness, diff, and delegation gates. No
  core runner, generic role, unit, retry/backoff, medic, or project-specific
  test changed. While this phase ran, the separately owned scribe fix committed
  as `cc5fae5` and the concurrent session advanced `origin/main` through that
  exact cumulative head; no history was rewritten or remote action taken by
  this executor.
- 2026-08-10 — Phase 2 plan: `builder: subagent (1 agent)` will cold-review the
  Phase 1 config/prompt/README evidence and the single controlled live-run
  artifacts. Root alone owns the live start, full gates, artifact capture,
  Ledger, staging, publication-status audit, notification, and merge stop.
- 2026-08-10 — Phase 2 hermetic/live verification: `builder: inline (gate
  commands and the single controlled service start the orchestrator must read
  itself)`. From clean committed head `2b8a971`, root passed syntax, Python
  compile, full Bats 817/817, leak, deck freshness/completeness/render,
  lifecycle, delegation, diff, and worktree-link gates. The pre-run public
  result was 538 bytes at checksum
  `da06a3e55a151d70e0ea8ae4ac49f5f5012eba2fe0a50cbab2291ca59a5c735d`,
  passed, and had no
  `batsGate`. The one and only `systemctl --user start` began at
  `2026-08-10T14:18:44Z`, blocked until `14:22:38Z`, and returned 0. The new
  532-byte result checksum
  `e43a1854e1a6fc285ed5e7445da59236a8b09e02207767369338ea015c84e11c`
  is valid JSON with top-level
  `pass:true`, no errors, and exact
  `batsGate={status:"completed",pass:true,exitCode:0}`. Log lines 3–4 and
  822–824 order blocking-gate start, TAP `1..817`, case 817, gate end exit 0,
  and done pass true/exit 0. Systemd reports `Result=success`,
  `ExecMainStatus=0`; events 689 and 699 record matching start/end with
  `status=ok`, `duration_s=234`, and `exit_code=0` (the routine notification
  decision at line 698 was correctly policy-suppressed). No rerun occurred.
- 2026-08-10 — Phase 2 cold review: `builder: subagent (1 agent)`. The reviewer
  found no drift: one TAP plan, 817 `ok`, zero `not ok`; exact config/prompt and
  result assertions; one start/end event pair; systemd success/exit 0; and no
  second start. `git diff origin/main..HEAD` contains only README and ticket
  delivery changes—no core runner, unit, tests, retry/backoff, installer,
  scripts, or hooks. The only remaining DoD item is publication of this
  root-owned final Ledger through green CI; the builder may not merge it.
- 2026-08-10 — publication route reconciled: `builder: inline (single-file
  edit in an already-read ticket)`. While execution was active, the concurrent
  session pushed cumulative head `cc5fae5` directly to `origin/main`; GitHub
  run `31396789550` passed git identity, lifecycle, deck, Bats, leak, and shell.
  That main already contains the medic feature and incoming scribe fix. This
  executor's remaining exact diff is only the proctor README/ticket commits, so
  it publishes those on the dedicated bugfix branch above and retains the
  human-only merge stop. No rebase, force-push, duplicate feature PR, or remote
  rewrite is permitted.
- 2026-08-10 — publication opened: `builder: inline (remote publication the
  orchestrator must perform)`. Exact verified head `0407abb` was pushed without
  switching local `main` and opened as PR
  `https://github.com/wabbazzar/shipyard/pull/20` against base `cc5fae5`.
  GitHub reports the PR open, non-draft, mergeable, and initially unstable while
  required checks run. This Ledger commit is the final intended head; push it to
  the same branch, wait for all required checks, alert once if green, and do not
  merge.

---

Run `execute-ticket` on this decision-complete ticket.
