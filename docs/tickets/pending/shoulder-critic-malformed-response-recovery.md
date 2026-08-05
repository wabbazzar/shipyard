# Bound and diagnose malformed shoulder-critic responses

- **Created:** 2026-08-05
- **Owner:** wabbazzar
- **Status:** POLISHED — decision-complete and ready for `execute-ticket`
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 8 (three phases: 3 · 3 · 2)
- **Refs:** `agents/release/critic-watch.sh:208-235`,
  `agents/release/critic-watch.sh:573-596`,
  `agents/release/critic-watch.sh:735-782`,
  `agents/release/critic-watch.sh:269-277`,
  `agents/lib/spawn.sh:100-289`, `tests/shoulder-mode.bats:351-387`,
  `agents/release/critic-stop-gate-lib.sh:409-416`,
  `skills/shipyard/inspect.py:1590-1625`,
  `docs/shoulder-mode.md:145-168`, `CLAUDE.md:44-137`, commit `2b503f4`

## Summary

Make a malformed cold shoulder-review response a bounded, diagnosable degraded
outcome. The watcher must keep malformed output fail-closed, but it must not
re-run the model forever on the same immutable diff, hide the reason parsing
failed, or omit that spend from the daily critic budget.

## Objective

For one immutable queued snapshot, Shipyard attempts a malformed generic critic
response at most three times, exposes a content-safe parse reason and attempt
count, and then records an explicit unavailable/exhausted outcome. A repaired
snapshot or later required-feedback turn may try again; a malformed response
never becomes a valid review and never silently clears a required-feedback
blocker.

## Problem / background

### Captured reproduction — Judgify Phase 0A review, 2026-08-05

A manual staged-diff shoulder review was run against three newly staged files
under session `manual-t59-pre-ner-dedup-v2`. The exact staged diff had SHA-256:

```text
0af853615d96570ad254d8ce535ff7b70045f519fe6e377220fcfa7b532c919a
```

The ordinary implementation gates were green: 26 focused tests, 23 repository
regression tests, Python compilation, and diff checks. The cold critic returned
`malformed critic response; queue kept` three times overall, including repeated
attempts against the v2 immutable snapshot. There was no parse diagnostic,
attempt count, or exhausted state, so the operator had to stop the retries
manually and record that shoulder review was unavailable rather than passed.
The contained two-file implementation was then committed in Judgify as
`dbfeb420994d9c0808f00f7bb731a88d57061aa3`, with that unavailable-review fact
in the commit message.

An earlier snapshot did produce a valid `0 block, 9 warn, 9 note` critique and
then hit a separate delivery-command error. That distinction matters: model
spawn, response parsing, and finding delivery are independent failure stages
and must retain independent retry state and diagnostics.

### Violated observable contract

`critic-watch.sh` already says a continuously polling watcher must not restart
a failed three-attempt cycle forever (`:208-211`). It implements immutable,
generation-scoped retry counters for:

- model spawn failures (`critic-spawn-attempts-*`, `:580-596`, `:735-764`);
- broken finding delivery (`critic-attempts-*`, earlier in the same script).

The response-validation branch added in `2b503f4` is different. A successful
spawn is immediately removed from the spawn-failure counter (`:766`), then a
missing/duplicate `TOKENS_HINT|<none>` sentinel or any nonconforming output line
only emits a generic event and returns (`:768-782`). There is no malformed
response counter, exhaustion gate, terminal event, or local diagnostic. The
next watcher pass therefore spends another model call on the same snapshot.

There is also a budget-accounting gap. `tokens_used_today()` sums only
`release.critique` events (`:269-277`), while
`release.critique.malformed_response` records no token count. Every malformed
attempt consumes real model tokens but is invisible to the daily shoulder
critic budget.

### Root cause and rival causes

| Candidate | Evidence | Verdict |
|---|---|---|
| The queue or staged diff changed between attempts | Review identity was pinned to one staged diff hash and the queue was intentionally retained. | Ruled out for the repeated v2 attempts. |
| The model process failed to start | The watcher reached the response parser with a successful spawn; spawn failures have a separate bounded path. | Ruled out as this failure class. |
| Delivery failed after a valid critique | This occurred on an earlier attempt, but malformed attempts never created findings or invoked delivery. | Separate failure, not the cause. |
| Strict output validation rejected the normalized final message | The only path producing the observed log is the sentinel/line-schema check at `critic-watch.sh:774-782`. | Ruled in. |
| Retry bookkeeping bounded the failure anyway | Spawn state is removed before parsing and no malformed-response state exists. | Ruled out. |
| Daily budget would eventually stop the loop | Malformed-attempt tokens are not counted by `tokens_used_today()`. | Ruled out. |

### Coverage gap

`tests/shoulder-mode.bats:351-387` proves one malformed response keeps the queue
and produces no findings, but it does not invoke the watcher repeatedly against
the same snapshot. No test asserts bounded retries, generation reset, terminal
unavailable status, diagnostic reason, or token-budget attribution for malformed
responses. The one-pass test therefore encoded fail-closed behavior without
covering the live polling lifecycle.

## Decisions

### Locked

| Decision | Rationale |
|---|---|
| Keep the parser strict | Extra prose, code fences, a missing/duplicate sentinel, or an invalid finding line cannot be treated as a reviewed release verdict. |
| Scope retry exhaustion to immutable work plus the urgent Stop turn | This matches `retry_generation()` and permits a genuinely changed diff or later required-feedback turn to test a repaired path. |
| Count every completed model invocation toward the daily budget | Billing/spend occurs even when Shipyard rejects the response. |
| Keep telemetry content-free | Events may contain enums, counts, byte sizes, hashes/opaque IDs under the existing lineage policy, harness metadata, and token classes; never raw response prose, prompts, diffs, filenames, or findings. |
| Preserve a bounded private diagnostic locally | Operators need to distinguish missing sentinel, duplicate sentinel, invalid line, empty normalized text, and envelope/normalization failure without leaking model output into the public event stream. |
| Keep spawn, parse, specialist, and delivery failures separate | A retry at one stage must not erase or masquerade as the status of another. |
| Never write a valid-response marker on malformed exhaustion | “Unavailable after retries” is not “review passed.” |
| Emit `release.critique.malformed_response` for nonterminal attempts and `release.critique.malformed_response_exhausted` for the third/terminal attempt | Every invocation has exactly one token-bearing event, while operators can distinguish retrying from terminal unavailability without double-counting spend. |
| Teach fleet inspection about both malformed event types | `skills/shipyard/inspect.py` enumerates critic outcomes; silently dropping the new events would hide the exact degraded state this ticket makes observable. Both are critic failures, and the terminal event carries the attempt count and reason. |
| Deploy the shared watcher only through an empty-queue launchd preflight | This checkout is fleet-live, and restarting a watcher with queued work can spend tokens or mutate live review state. A nonempty queue defers that consumer restart; it never authorizes a model call. |
| The owner's 2026-08-05 “drop it through the pipe” instruction authorizes normal pipeline delivery | Commit on `main`, reconcile and push without force, and restart only empty-queue launchd consumers after green gates. It does not authorize discarding either git history, restarting queued consumers, or issuing real model/network review calls. |

### Open decisions with defaults

| Question | Default |
|---|---|
| Terminal behavior when `require_feedback=false` | After attempt 3, emit an exhausted event, preserve the bounded private diagnostic, consume only the exact reviewed queue prefix, and stop spending on that generation—parallel to non-required spawn exhaustion. |
| Terminal behavior when `require_feedback=true` | Preserve the queue, persist the exhausted generation, and write a terminal `malformed_response_exhausted` status so the Stop path reports an honest hard blocker without polling the model again. |
| Private diagnostic shape | Mode-0600 JSON beside existing critic state with schema version, reason enum, invalid-line count, sentinel count, response byte count/hash, harness, token count, attempt, generation, and timestamp. Do not store raw response text by default. |
| Retry limit | Three attempts, matching existing spawn and broken-delivery behavior. |

### User-decision class

None. This restores the watcher's already-stated bounded-retry contract without
loosening review validation or increasing the retry ceiling. The normal
commit/push and empty-consumer deployment authority is locked above.

**Auto-gate: PROCEED.** Defaults above are implementation choices, not blockers.

## Verified polishing baseline — 2026-08-05

| Surface | Observed evidence | Execution consequence |
|---|---|---|
| Project authority | `.agents/config.toml` and `.agents/gates.md` are absent and intentionally ignored by `.gitignore`; `skills/gates.md.template` is not a filled project gate. `CLAUDE.md:44-74` is the checked-in gate authority for this source repo. | Use the exact checked-in commands below. Do not infer autonomy, merge permission, or notification configuration. Work directly on `main`, in this checkout, in small green commits. |
| Toolchain | `bats --version` → `Bats 1.14.0`; Bash, `jq`, Python 3.11, Node, `plutil`, and `launchctl` are present. `bash -n agents/release/critic-watch.sh agents/lib/spawn.sh` → 0; `bash scripts/check-deck-fresh.sh` → 0; `git diff --check` → 0. | The ticket's shell/Bats/deck/diff verification surface exists. `shellcheck` is absent and is not a canonical Shipyard gate. |
| Current test inventory | `bats --count tests/shoulder-mode.bats` → 63; `bats --count tests/codex-feedback-delivery.bats` → 53. Two narrow baseline runs stalled before a case completed and were terminated with no remaining child processes. | Establish a trustworthy green focused/full baseline after the polished-ticket commit and before implementation. A hang is not a green result and must be diagnosed rather than bypassed. |
| Captured incident | Judgify's current-day event JSONL contains one valid `release.critique` with 25,023 tokens and three `release.critique.malformed_response` records with no reason or token attribution. Commit `dbfeb420994d9c0808f00f7bb731a88d57061aa3` records the same unavailable review. | Keep runtime evidence content-safe and use hermetic fixtures for the regression; do not replay a real model call. |
| Existing primitives | `critic-watch.sh:147-253` provides private-file validation, atomic status writing, generation IDs, and retry counters; spawn and delivery already have independent three-strike state. `:768-782` is the unbounded parser branch and `:269-277` omits malformed spend. | Extend the existing state vocabulary; do not merge parser state with spawn/delivery state. Apply regular-file/owner/mode/link-count checks to the new diagnostic and counter paths. |
| Live consumers | On this Darwin host, loaded launchd labels `com.shipyard.judgify-release-watch` and `com.shipyard.distillery-release-watch` both execute this checkout's watcher as long-lived pollers. Judgify's queue was empty; Distillery had two nonempty queues at discovery time. | Never kickstart from stale discovery. Recheck each queue immediately before restart, deploy only empty consumers, and record any deferred consumer honestly. No restart may cause a model/network invocation. |
| Repository state | `main` is locally divergent from `origin/main`; the handoff ticket is the only worktree change. `core.hooksPath` is unset. | Scope every add. Run leak-check explicitly before each commit. Reconcile remote divergence without a branch/worktree and rerun all gates before any push. |
| Specialist routing | No `.agents/specialists/*.toml` manifests are installed. | No specialist review applies to this ticket. |

## Technical requirements

### Parse classification and private evidence

- Extract generic response validation into a deterministic helper or tightly
  scoped function that returns a stable reason enum at minimum:
  `empty_text`, `missing_sentinel`, `duplicate_sentinel`, and `invalid_line`.
  If the harness envelope cannot be normalized despite exit 0, classify it
  separately from output-schema violations.
- Record only content-safe fields in JSONL events. Never include the invalid
  line, raw response, prompt, diff, file path, or finding text.
- Write diagnostic state atomically with owner-only permissions and the same
  symlink/ownership discipline used by existing private shoulder state. Bound
  all sizes and counts before writing.
- Include actual token usage from `SPAWN_TOKENS` in each malformed-attempt event
  and make `tokens_used_today()` include that spend exactly once.

### Snapshot-scoped retry and exhaustion

- Add malformed-response retry state keyed by
  `retry_generation malformed "$session" "$snapshot_id"`; do not reuse the
  spawn or delivery counter.
- Increment it only after a successful model invocation reaches and fails the
  generic response parser. A spawn failure must remain a spawn attempt; a valid
  parsed response must clear stale malformed state for that generation.
- Attempts one and two retain the exact reviewed queue and log `(N/3)` plus the
  reason enum. Attempt three emits a terminal exhausted event with reason,
  attempts, files, and tokens, then follows the locked required/non-required
  behavior above.
- A continuously polling watcher must perform zero additional model calls once
  that generation is exhausted. A changed queue snapshot or later urgent turn
  creates a new generation and may retry.
- Specialist-response parsing remains a distinct failure stage. Do not silently
  claim this generic-parser repair also bounds specialist malformed responses;
  either apply the same primitive explicitly with stage=`specialist` and tests,
  or leave a named follow-up/out-of-scope note.

### Documentation and operator contract

- Update `docs/shoulder-mode.md` with malformed-response retry/exhaustion
  semantics, the content-safe diagnostic surface, and budget attribution.
- Document the terminal required-feedback meaning: review unavailable after
  bounded attempts, queue preserved, no valid marker, human/agent must record
  the blocker or change the reviewed work/turn before another attempt.
- Keep existing successful review and cached delivery semantics unchanged.

## Implementation plan

### Phase 1 — reproduce and classify the malformed lifecycle (3 pts)

- **Files owned:** `agents/release/critic-watch.sh`,
  `tests/shoulder-mode.bats`. Do not touch retry policy, Stop handling,
  documentation, or fleet inspection in this phase.
- Add named Bats cases for `empty_text`, `missing_sentinel`,
  `duplicate_sentinel`, invalid finding lines, and an exit-0 envelope that
  cannot normalize. Use PATH shims only; never call a real harness or network.
- The lifecycle fixture must run the watcher four times against one immutable
  staged snapshot. Before implementation it must prove the defect: four model
  invocations, no exhausted event/status, and malformed tokens absent from the
  daily sum. Preserve that red output in the Ledger.
- Extract deterministic generic-response classification. Write a bounded
  schema-v1 diagnostic atomically with mode 0600 and validate regular-file,
  current-owner, non-symlink, and link-count-one constraints before reuse.
  Assert the public event and private diagnostic omit response prose, prompt,
  diff, path, filename, and finding text.
- Keep behavior unchanged except for classification/private evidence: this
  phase does not yet suppress the fourth call.

**Delegation: subagent.** Starting from the polished ticket and the existing
one-pass malformed fixture, own only the two files above. Build the failing-
first fixture matrix and parser/diagnostic primitive; do not implement retry
exhaustion early. Return no more than 40 lines containing files changed,
commands with exit codes/test counts, the pre-change fourth-call evidence,
diagnostic permission/content-safety evidence, and blockers.

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives. If it needs a spend,
> an outward-facing action, or a destructive change, stop and report instead.

**Phase 1 verification surface:**

```bash
bash -n agents/release/critic-watch.sh
bats --filter 'malformed response (classification|diagnostic|lifecycle)' tests/shoulder-mode.bats
bash scripts/leak-check.sh
git diff --check
```

Observable DoD: the red-first Ledger records the fourth pre-change invocation;
the focused Bats cases then pass with stable reason enums, a safe 0600 private
artifact, and content-free events, while still proving retry policy is not yet
claimed by this slice.

### Phase 2 — bound retries and account for spend (3 pts)

- **Files owned:** `agents/release/critic-watch.sh`,
  `agents/release/critic-stop-gate-lib.sh`, `tests/shoulder-mode.bats`, and
  `tests/codex-feedback-delivery.bats`.
- Add `retry_generation malformed "$session" "$snapshot_id"` state. Increment
  it only after a successful generic model invocation fails parser validation;
  clear it after a valid parse. Reuse neither spawn nor delivery counters.
- Attempts one and two emit `release.critique.malformed_response`. Attempt
  three emits only `release.critique.malformed_response_exhausted`, persists
  terminal status in required mode, and prevents a fourth model call for the
  generation. Each event carries its own invocation's `SPAWN_TOKENS` exactly
  once plus reason, attempt, generation, and file count.
- Cover non-required exact-prefix consumption, required queue preservation and
  hard blocker, changed-snapshot reset, later-urgent-turn reset, valid-second-
  response recovery, and state isolation from spawn/delivery failures.
- Add `malformed_response_exhausted` to the Stop terminal-status fixture. A
  malformed path never writes a valid marker or invokes finding delivery.

**Delegation: subagent.** Implement the bounded retry/budget slice against
Phase 1's red lifecycle fixture. Own only the four files above. Preserve spawn,
specialist, and cached-delivery behavior. Return no more than 40 lines containing
files changed, commands with exit codes/test counts, exact call counts, sample
content-safe events/status, queue assertions, and blockers.

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives. If it needs a spend,
> an outward-facing action, or a destructive change, stop and report instead.

**Phase 2 verification surface:**

```bash
bash -n agents/release/critic-watch.sh agents/release/critic-stop-gate-lib.sh
bats --filter 'malformed response (lifecycle|retry|budget|required)' tests/shoulder-mode.bats
bats --filter 'terminal critic failure state' tests/codex-feedback-delivery.bats
bash scripts/leak-check.sh
git diff --check
```

Observable DoD: fixture logs show three model calls and zero on the fourth pass;
event token totals equal the three stubbed invocations exactly once; required
and non-required queue/status assertions pass; changed work and a later urgent
turn each obtain a fresh generation.

### Phase 3 — operator docs and full regression (2 pts)

- **Files owned:** `docs/shoulder-mode.md`, `skills/shipyard/inspect.py`,
  `tests/shipyard-inspect.bats`, and this ticket's Ledger/status. Product-code
  edits from Phases 1-2 are verification inputs, not Phase 3 ownership.
- Document retry generation, attempt/exhausted event schemas, private
  diagnostic fields/safety, budget attribution, exact-prefix consumption, and
  the required-feedback hard-blocker contract.
- Parse both malformed event types as `critique_event` in fleet inspection;
  count token/file fields once, retain the reason/attempt evidence, and treat
  them as critic failures for health/priority derivation. Add a hermetic inspect
  fixture proving the new events are not silently discarded.
- Verify the existing valid response, cached delivery, spawn failure,
  specialist, Claude, Codex, and Hermes fixtures remain unchanged.
- Deploy only after every repository gate is green. For each loaded Darwin
  consumer, lint and print its launchd job, then prove its project has no
  nonempty `tmp/critic-queue-*` file immediately before `kickstart -k`. Skip and
  record any nonempty consumer; do not cause a model call. After a safe restart,
  print the new PID/state and inspect that project's current-day event JSONL for
  watcher errors. On non-Darwin hosts, record launchd as not applicable rather
  than inventing a systemd deployment.
- Reconcile `main` with `origin/main` in this checkout (no branch/worktree),
  rerun the full gate after reconciliation, then push only if the remote can be
  fast-forwarded without discarding either history.

**Delegation: subagent.** Update the canonical docs and fleet-inspection parser
plus its hermetic fixture. Do not restart live watchers or push; the orchestrator
owns those actions and re-verifies all gates. Return no more than 40 lines with
files changed, commands with exit codes/test counts, inspect evidence, docs
sections, and blockers.

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives. If it needs a spend,
> an outward-facing action, or a destructive change, stop and report instead.

**Phase 3 repository verification surface:**

```bash
bats tests/
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh
python3 -m py_compile skills/shipyard/inspect.py
node scripts/check-deck-render.mjs  # rc 0, or documented rc 3 when Playwright is absent
git diff --check
```

**Phase 3 Darwin deployment surface (read-only until the queue assertion):**

```bash
for project in judgify distillery; do
  label="com.shipyard.${project}-release-watch"
  plutil -lint "$HOME/Library/LaunchAgents/${project}-release-watch.plist"
  launchctl print "gui/$(id -u)/$label"
  test -d "../$project/tmp"
  if [ -n "$(find "../$project/tmp" -maxdepth 1 -type f -name 'critic-queue-*' -size +0c -print -quit)" ]; then
    echo "DEFER restart: $project has queued critic work"
    continue
  fi
  launchctl kickstart -k "gui/$(id -u)/$label"
  launchctl print "gui/$(id -u)/$label"
  test ! -f "../$project/data/events/$(date +%F).jsonl" || \
    jq -e . "../$project/data/events/$(date +%F).jsonl" >/dev/null
done
```

The final JSONL read is observational, not a requirement that a failure event
exist. Observable DoD: full gates pass with measured counts; inspection retains
both new event types; every restarted watcher has a new running launchd process
after an empty-queue assertion; every deferred watcher is named in the Ledger;
the repository is reconciled and pushed without force.

## Testing strategy

- Use Bats PATH shims only; no test calls a real model, network, authoring
  session, or notification transport.
- Demonstrate each new lifecycle test failing against pre-change code before
  implementation, especially the fourth model call and invisible token spend.
- Assert call counts and exact state/event fields rather than matching only a
  log substring.
- Exercise both `CRITIC_DIFF_MODE=staged` (the captured incident) and the
  default branch mode where shared logic applies.
- Exercise fleet inspection with synthetic JSONL only. Assert both new event
  names, reasons, attempts, token totals, and recurrence/fault classification.
- Run every focused and full Bats command with a bounded outer timeout while
  diagnosing the polishing-time stall; a timeout is a red gate and its process
  group must be terminated and checked for leftovers.
- Before every phase commit, rerun that phase's exact gate as orchestrator,
  run `git status --short`, and scope `git add` to the named files.
- Run the repository's canonical gates:

```bash
bats tests/
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh
python3 -m py_compile skills/shipyard/inspect.py
node scripts/check-deck-render.mjs  # rc 0 or documented optional-tool rc 3
git diff --check
ps -eo pid,command | grep -iE '[c]hrome-headless|[h]eadless' || true
bash scripts/ticket-lifecycle.sh --project . --check  # current config: expected no-op rc 3
```

## Definition of Done

- [ ] The captured repeated-malformed lifecycle is represented by a deterministic failing-first Bats fixture.
- [ ] One immutable snapshot receives at most three malformed generic-review attempts; a fourth watcher pass makes zero model calls.
- [ ] Retry state resets only for a changed snapshot or later urgent turn and clears after a valid parsed response.
- [ ] Malformed output never writes `critic-valid-response-*`, never delivers findings, and never counts as a passed review.
- [ ] Non-required exhaustion consumes only the reviewed queue prefix; required exhaustion preserves the queue and surfaces a terminal hard blocker.
- [ ] Events expose a stable parse-reason enum, attempt count, token usage, and terminal exhaustion without response prose, prompts, diffs, filenames, or findings.
- [ ] A bounded, private diagnostic artifact is atomic, owner-only, content-safe by default, and linked to the retry generation.
- [ ] Every malformed invocation is included exactly once in the daily shoulder token budget.
- [ ] Spawn failure, specialist failure, and delivery retry behavior remain independently tested and unchanged unless explicitly extended.
- [ ] Canonical shoulder-mode docs describe retry, exhaustion, diagnostics, and budget semantics.
- [ ] Fleet inspection retains both malformed event types, their safe fields, and their failure recurrence without double-counting tokens.
- [ ] Every loaded Darwin watcher restarted by this ticket had an immediately preceding empty-queue assertion and is running afterward; a nonempty consumer is deferred without a model call and named in the Ledger.
- [ ] Remote divergence is reconciled without a branch, worktree, force-push, or discarded history; the full gate is rerun after reconciliation.
- [ ] Focused tests, full Bats, shell syntax, leak check, deck freshness, and diff check pass.

## Dependencies

- Existing snapshot identity and `retry_generation()` primitives in
  `critic-watch.sh`.
- Existing private shoulder status/state helpers and Bats PATH-shim harness.
- Commit `2b503f4`, which introduced strict generic and specialist response
  validation and the valid-response marker.

## Risks and mitigations

- **Leaking model output:** keep public events enum/count/hash-only and default
  private diagnostics to metadata, not raw text.
- **False pass after exhaustion:** never create a valid marker or findings file;
  name the state unavailable/exhausted, not clean.
- **Dropping later edits:** consume only the lock-protected reviewed prefix in
  non-required mode; preserve later queue entries.
- **Retry lockout after a real repair:** bind state to snapshot plus urgent turn,
  matching the existing generation primitive.
- **Budget double count:** attribute tokens once per model invocation and test a
  malformed-then-valid sequence.
- **Conflating generic and specialist parsers:** retain an explicit stage field
  and require separate tests before sharing exhaustion behavior.
- **Restarting queued live consumers:** run the empty-queue assertion
  immediately before each launchd kickstart; defer nonempty projects and never
  turn deployment verification into an unapproved model invocation.
- **Stale long-lived watcher code:** a committed source edit is not loaded by an
  already-running shell process; safely kickstart each empty consumer and print
  its replacement launchd process state.
- **Divergent `main`:** reconcile both histories in the one live checkout,
  rerun the complete gate, and never force-push or discard another session's
  commits.

## Out of scope

- Weakening the critic output grammar or accepting prose/code fences as a valid
  review.
- Changing the critic rubric, severity meanings, model/provider selection, or
  three-attempt ceiling.
- Retrying delivery by re-running a valid critique; cached delivery remains the
  required behavior.
- Storing raw prompts, diffs, response prose, filenames, or findings in the
  event stream.
- Changing Airflow, Judgify pipeline code, or the committed T59 implementation
  that exposed this Shipyard defect.

## Ledger

- 2026-08-05 — draft created from the Judgify T59 live incident. No Shipyard
  runtime code changed and no model/network call was made while drafting.
- 2026-08-05 — polished by orchestrator after three delegated read-only sweeps:
  repository conventions, parser/test surface, and live-consumer state.
  `builder: inline (ticket-only edit retained by polish orchestrator)`.
  Exact toolchain, live launchd preflights, phase ownership, delegation briefs,
  observable gates, and auto-gate were pinned above. No watcher was restarted
  and no model/network call was made. Polished-ticket commit is recorded by
  Phase 1 after the hash exists.
- 2026-08-05 — execution preflight plan: `builder: inline (one-line fixture
  correction in an already-read file, under the execute-ticket exception)`.
  The native-Python baseline reached case 7 and failed because the Hermes
  success stub predates strict generic-response validation and omits the clean
  sentinel introduced by `2b503f4`; the isolated case reproduces the failure.
  Add only `TOKENS_HINT|<none>` to that success stub, prove the isolated guard
  passes, then rerun the focused/full baseline before runtime edits.
- 2026-08-05 — execution preflight result: the isolated Hermes guard passed
  1/1 and `tests/shoulder-mode.bats` passed 63/63 with native macOS Python
  ahead of the interactive pyenv shim. The unqualified interactive PATH had
  stalled in `_cq_outer_lock_create`; no Bats/queue-hook children remained
  after its bounded termination. This slice changes no runtime behavior and
  makes the strict-parser guard truthful. Commit hash is recorded in Phase 1.
- 2026-08-05 — full-baseline repair plan: `builder: subagent (1 agent)` owning
  only `tests/codex-feedback-delivery.bats`. The 778-case run reached case 25
  before being stopped: cases 12/13 failed after strict parsing rejected stale
  success stubs, and case 25 waited indefinitely for an obsolete external
  `stat` seam that the current fd/Python lock path does not call. Repair only
  those fixtures, retain their delivery/queue/race assertions, bound every
  wait, prove the three isolated cases, then restart the full baseline. No
  runtime code or live consumer is in scope for this repair.
- 2026-08-05 — full-baseline repair result: four valid generic-review fixtures
  now include the strict clean sentinel. The owner-handoff race derives the
  background shell PID portably (including native Bash 3.2), and all marker
  waits are bounded. Isolated repaired cases passed; the complete
  `tests/codex-feedback-delivery.bats` file passed 53/53 and the earlier
  `tests/shoulder-mode.bats` run passed 63/63. Runtime files remain untouched.
- 2026-08-05 — macOS harness follow-up: `builder: inline (test-only setup in
  already-read files)`. Homebrew Bash 5.3 stalls in the watcher's heredoc lock
  helper, while globally replacing PATH breaks unrelated fixtures. The bounded
  gate therefore shims only `bash` to `/bin/bash`; critic/doctor fixtures resolve
  their native developer-tool Python locally before changing fixture `HOME`,
  and dashboard fixtures retain their pre-`HOME` real interpreter. Evidence:
  the full run passed all 59 Codex cases before reaching dashboard; dashboard
  then passed 9/9 after its scoped fix; doctor timing passed on retry under
  current host load; no runtime file changed.
- 2026-08-05 — shared harness repair plan: `builder: inline (test-only helper
  consolidation and one stale fixture in already-read files)`. The continued
  baseline exposed the invoking user's pyenv shim after fixture `HOME` changed,
  causing release-gate timeouts unrelated to product behavior. Resolve the real
  Python interpreter before changing fixture `HOME` in `quartet_setup`, place it
  behind explicit test stubs, remove three duplicate per-file setups, and add the strict clean
  sentinel to the cached-delivery success fixture. Invoke watcher fixtures with
  `/bin/bash`, matching the launchd plist, while leaving the overall suite on
  its canonical command PATH. Because Homebrew Bash 5.3 hangs in this host's
  Bats preprocessor, the gate may put `/bin/bash` first for Bats itself and pass
  the original PATH through `SHIPYARD_TEST_COMMAND_PATH` for fixtures. Prove the
  affected files and failed cases before restarting the complete baseline; no
  live consumer is in scope.
- 2026-08-05 — stock-Bash baseline repair plan: `builder: inline (one portable
  empty-array expansion in an already-traced runtime file)`. A retained-fixture
  `bash -x` reproduction proved that ordinary release success reaches its final
  event and then exits at `RELEASE_FINISH_OPTIONS[@]: unbound variable` under
  installed macOS Bash 3.2; Bash 5 masks the defect. Use the same guarded array
  expansion already established in `critic-watch.sh` for the release options
  and the build ticket-lineage list (the latter fails identically when
  telemetry is disabled), then prove release, medic, and ticket-dispatch cases
  under stock Bash before committing this independent enabling repair.
- 2026-08-05 — shared/stock-Bash baseline repair result: the watcher suite
  passed 63/63 and Codex delivery passed 53/53 under `/bin/bash`; cached
  delivery passed 1/1. Release blocking gates passed 11/11, stall handling
  passed 12/12, medic notification lineage passed 2/2, and enabled ticket
  dispatch passed 1/1 under stock Bash after the guarded array repairs. With
  native Bash restricted to Bats plus watcher launchd parity and the original
  command PATH restored to fixtures, the doctor performance guard passed 1/1.
  No live consumer, model, or network call was made. The complete 778-case
  baseline remains the next gate before Phase 1 product work.
- 2026-08-05 — complete-baseline shell follow-up: cases 1–44 passed. Case 45's
  maximum-size Codex Stop hook stalled because only watcher invocations, not
  the sibling critic hooks, had launchd's `/bin/bash`; the process tree pinned
  the active child to `critic-stop-gate-codex.sh` and its nested Python read.
  Add a Darwin-only helper that hook-focused files opt into, prove the captured
  case plus the critic files, then restart the complete baseline. The stopped
  run made no model/network call and left no test child running.
- 2026-08-05 — complete-baseline shell follow-up result: the captured
  maximum-size Codex Stop case passed 1/1 and the cross-harness critic hook file
  passed 20/20 with the opt-in native Bash helper. No test child remained. This
  is a test-runtime correction only; the complete baseline is restarted next.
- 2026-08-05 — complete-baseline shell follow-up 2: cases 1–91 passed, including
  the formerly stalled case 45. Case 92 pinned a second Homebrew Bash stall to
  `sync-deck-mirror.sh`, proving the incompatibility is not critic-specific.
  Keep the native-Bash shim for all fixtures; only doctor resolves the original
  Bash before setup and uses it for its explicit sub-five-second performance
  assertion. Prove doctor performance and deck mirror, then restart the full
  baseline. The stopped run left no test child and made no model/network call.
- 2026-08-05 — complete-baseline shell follow-up 2 result: doctor performance
  passed 1/1 with the explicitly captured original Bash, and deck mirror passed
  10/10 with native Bash fixtures, including the captured sync case. The full
  baseline is restarted next; no publication or live-consumer action occurred.

---

Run `execute-ticket` on this decision-complete ticket.
