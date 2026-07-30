# Deliver release-critic findings into the authoring Codex session

- **Created:** 2026-07-30
- **Owner:** wabbazzar
- **Status:** Complete
- **Type:** bugfix
- **Estimated Points:** 8
- **Refs:** `docs/tickets/complete/harness-agnostic-shoulder-mode.md`,
  `docs/shoulder-mode.md`, `.agents/gates.md`

## Goal

Restore the shoulder-mode contract for Codex: a Codex edit is captured, the
cold release critic reviews the resulting diff, and the resulting findings
return as model-visible context to the same Codex session. A human-only alert,
a log line, or delivery to a Claude tmux pane does not satisfy this contract.

The fix must also make installation and doctor output honest. A project whose
active authoring harness is Codex must not report a clean shoulder install when
Codex capture or in-band delivery is absent.

## Captured defect

The live Aurora install on 2026-07-30 reproduces the defect:

- Codex hooks are stable and enabled (`codex-cli 0.146.0`), but
  `sw_wired codex ~/.codex/config.toml .../critic-queue-codex.sh` exits `1`.
- Aurora has no project Codex hook and no Codex hook in the user config.
- `install.sh --project <aurora-project> --doctor` exits `0` and says
  checks a-j are clean despite that missing capture path.
- `aurora-proctor-watch.service` is active, but its delivery command targets a
  legacy Claude tmux injector.
- Calling `critic-note.sh --harness codex` without a custom injector prints
  `no delivery channel ...; skipping` and exits `0`. The watcher therefore
  treats an undelivered finding as delivered and may clear its queue.
- The current focused tests pass 29/29 because they cover capture parsing,
  additive wiring, and owner-alert fallback, but never assert
  `Codex edit → queue → critic → model-visible same-session finding`.

Official Codex hook behavior rules out the rival explanation that Codex cannot
receive model-visible hook feedback. `PreToolUse` and `PostToolUse` command
hooks can return `hookSpecificOutput.additionalContext`; a `Stop` hook can
continue the turn with a reason. The missing component is Shipyard's
asynchronous delivery bridge.

## Root cause

The 2026-07-24 harness-agnostic shoulder work normalized Codex edit capture but
never implemented native same-session Codex delivery:

- `critic-queue-codex.sh` only writes the edit queue and returns no hook
  context.
- `critic-watch.sh` produces findings after the capture hook has already
  returned, so direct output from that capture invocation cannot deliver the
  later result.
- `critic-note.sh` explicitly has no Codex-native channel and treats fallback
  logging or human notification as successful delivery.
- `--wire-shoulder` registers capture and writes an env fragment, but does not
  provision or reconfigure the long-lived watcher that must source it.
- doctor only checks shoulder wiring after another marker says the project
  opted in, allowing an active legacy watcher to be falsely clean.

This is a latent design and coverage gap, not an intermittent Aurora failure.
It affects any Codex-authored project installed in the same shape.

## Required behavior

1. Every completed Codex critique is an immutable, atomically persisted item
   for its originating `session_id`; later critiques cannot overwrite earlier
   undelivered items and findings cannot cross sessions.
2. A Codex hook at the next supported local-tool boundary emits pending items
   as concise `additionalContext`, the official model-visible output shape.
   Shipyard can guarantee durability only through one valid hook-emission
   attempt because Codex provides no model-consumption acknowledgement. Every
   item carries a stable critique ID; an ambiguous pre-emission crash replays,
   while post-emission model consumption remains explicitly unacknowledged.
3. The final-turn path cannot silently lose a pending critique. In required
   mode, a Codex `Stop` hook must deliver completed items or request an urgent
   watcher flush, bypass debounce, wait/continue only within a bounded state
   machine, and surface a hard blocker for budget, spawn, watcher-down, or
   delivery failure instead of spinning or pretending success.
4. Capture, critique, durable deposit, hook emission, and model consumption are
   distinct states. The watcher may clear the edit queue after a durable
   deposit; it must not equate a human alert or log-and-skip with model
   delivery.
5. Missing, malformed, stale, concurrent, or raced mailbox files fail safely
   without corrupting another session. The filesystem contract uses hashed
   session keys, immutable item IDs, a cross-process lock, bounded content,
   claim recovery, and explicit garbage collection; no transcript or secret is
   copied into tracked files.
6. `install.sh --wire-shoulder` additively wires Codex capture, delivery-drain,
   and stop-backstop hooks and provisions or updates the project watcher so its
   generated environment is actually used.
7. Existing installs remain unchanged when shoulder wiring is not opted in.
   The unset value is exactly today's behavior.
8. Doctor reports actionable drift when an active project's declared
   authoring harness lacks capture, the model-visible delivery hook, the stop
   backstop, the generated env, or watcher use of that env.
9. A real fresh Codex session proves the full chain using a deliberate edit and
   a deterministic watcher trigger. The proof must observe the queue entry,
   critique event, mailbox transition, and the release finding in model-visible
   Codex context.

## Scope

Likely production surfaces:

- `agents/release/critic-watch.sh`
- `agents/release/critic-note.sh`
- a small Codex feedback mailbox/drain hook under `agents/release/`
- `agents/release/critic-stop-gate-codex.sh`
- `agents/lib/shoulder-wire.sh`
- `install.sh`
- shoulder-mode tests and documentation

The builder may choose a smaller equivalent arrangement if it preserves the
required state transitions and observable contract.

## Boundaries

- Do not give the critic the authoring transcript; cold-context review remains
  the point of shoulder mode.
- Do not make critique synchronous with every edit. Capture stays fast and
  critique stays debounced/asynchronous.
- Do not treat Signal, terminal output, a watcher log, or a Claude-pane message
  as Codex model delivery.
- Do not weaken the existing queue retry or token-budget controls.
- Do not broaden this ticket into critic prompt-quality changes.
- Do not resume Aurora ticket 043 until the fresh-session live proof passes.

## Decisions

### Locked

| # | Decision |
|---|---|
| D1 | The user's instruction to make release feedback work for Codex before any Aurora work explicitly authorizes updating the live Shipyard shoulder automation and reinstalling Aurora's watcher. |
| D2 | Delivery is asynchronous and same-session: persist immutable items by a hash of Codex `session_id`, then surface on the next local-tool boundary with a bounded Stop urgent-flush backstop. |
| D3 | A human alert is an optional duplicate notification, never proof of Codex delivery. |
| D4 | Install remains opt-in; unset behavior stays byte-for-byte equivalent. |
| D5 | The full acceptance gate uses a fresh Codex process because a running process does not reload new hook definitions. The builder must review/trust the exact definitions through `/hooks`; bypassing trust is allowed only for the separate isolated automation probe and does not prove the normal install trusted. |
| D6 | `require_feedback = true` is fail-closed but bounded: it may continue a Stop turn at most twice. The first continuation requests/awaits urgent flush; the second reports an explicit release-critic hard blocker. A third Stop may end only after that blocker is the last assistant outcome. |
| D7 | Authoring and reviewing harnesses are independent config axes. `[shoulder] harness` selects the active session that receives findings; `[shoulder] critic_harness` selects the cold release model. Both accept `claude`, `codex`, or `hermes`; changing either is configuration, never a code fork. |
| D8 | This repair must preserve the existing Claude injector/fallback and Hermes native-send behavior with compatibility tests. Adding native Codex delivery must not make either existing pathway blocked, deprecated, or subordinate. |

### Open with defaults

| # | Question | Default |
|---|---|---|
| O1 | Mailbox storage shape | A user-private XDG state root, `${XDG_STATE_HOME:-$HOME/.local/state}/shipyard/critic-feedback`, with an installer-owned allowlist and `<sha256(canonical-project)>/<sha256(session_id)>/{pending,claims,emitted,quarantine}/<epoch>-<critique_id>.json`; schema version 1, mode `0700` directory/`0600` file, no symlink components/items, a 128 KiB hook-input cap, 8 KiB and 50-line summary cap, checked SHA-256 operations, stable critique ID, oldest-first drain, token+PID/process-start-identity `mkdir` lock recovery, and 7-day emitted/quarantine cleanup. |
| O2 | Hook boundary | Drain on all supported local `PostToolUse` events; use `Stop` for final-turn delivery/pending-work continuation. This preserves asynchronous critique and avoids blocking every edit. |
| O3 | Required-feedback policy | Add `[shoulder] require_feedback`; unset/false remains note-only, while Aurora enables it for the repair and resumed ticket. |
| O4 | Critic harness for Aurora | Set `[shoulder] critic_harness = "codex"` so the installed watcher uses the available authenticated harness instead of the currently failing Claude spawn path. |

### User-decision class

None open. The owner explicitly paused all other work and approved repairing
and proving this live automation first.

## Context and code pointers

- `agents/release/critic-watch.sh:107-205` owns queue consumption and the
  delivery exit-code contract. `deliver_findings` must acknowledge the edit
  queue only after a durable Codex mailbox deposit.
- `agents/release/critic-watch.sh:207-412` owns cached findings, model spend,
  snapshots, event emission, and the final `deliver_findings` call. Keep the
  critic cold and preserve those budget/snapshot semantics.
- `agents/release/critic-note.sh:35-72` is the shipped delivery dispatcher.
  Its `codex|claude` fallthrough and exit-0 log-and-skip are the immediate
  false-success defect.
- `agents/release/critic-queue-codex.sh` is capture-only. Do not make it wait
  for the critic; add an independent hook for completed feedback.
- `agents/release/critic-stop-gate-codex.sh` and
  `agents/release/critic-stop-gate-lib.sh` implement the current opt-in Stop
  teeth. Extend rather than duplicate the block-finding logic.
- `agents/lib/shoulder-wire.sh:38-53` currently appends only one Codex
  `PostToolUse` capture hook. Codex accepts multiple additive hook entries and
  uses `matcher = "*"` (or omitted matcher) for all local tools.
- `install.sh:330-352` is the false-clean doctor check.
  `install.sh:943-980` writes capture plus an env fragment but no watcher unit.
- `tests/shoulder-mode-harness.bats` and `tests/shoulder-wire.bats` are the
  nearest focused fixtures. `tests/helpers.bash` supplies hermetic PATH and
  systemd shims; tests must not call a model or network.
- Official Codex hook behavior is the implementation contract:
  `PostToolUse` exit-0 JSON with
  `hookSpecificOutput.hookEventName = "PostToolUse"` and
  `additionalContext` is model-visible; `Stop` `decision = "block"` continues
  the turn with `reason` as the continuation prompt. Plain stdout is ignored.
  Hooks load at process start and require trust; an isolated debug probe may
  use `--dangerously-bypass-hook-trust` only after inspecting the definitions,
  while final acceptance requires a fresh normal process after `/hooks` trust.

## Verification contract

Every implementation phase applies the shell, bats, config-additivity,
public-repo, and delegation gates in `.agents/gates.md`. Phases touching unit
generation also apply the systemd gate. The final phase runs every command
below:

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
bash scripts/ticket-lifecycle.sh --project . --check
./install.sh --doctor --project .
git diff --check
```

Any new tracked file must be staged with `git add -N` before leak-check; an
untracked file is otherwise outside that gate. No phase commits a red test:
the builder must first demonstrate the new case fails against an isolated copy
of pre-change `main`, then make it green in the working tree.

## Implementation plan

### Phase 1 — Durable per-session delivery and model-visible hook (3 pts)

**Slice.**

- Add `agents/release/critic-codex-feedback.sh`. On a Codex `PostToolUse`
  payload it resolves the canonical project from `.cwd`, requires that exact
  project in the private installer-owned allowlist, hashes canonical project
  plus opaque `.session_id`, takes the token/PID/process-start-safe session
  lock, recovers dead-owner claims, and claims the oldest immutable schema-v1 item from the
  external XDG state root. No workspace-controlled file can become hook
  context. With no pending item it exits `0` silently. With one, it emits
  exit-0 JSON exactly shaped as
  `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":
  "Release critic [<critique-id>]: ..."}}`. Plain stdout is invalid and normal
  comment delivery must not use `decision:block` or `continue:false`, because
  those replace the completed tool result. After successful JSON emission the
  item moves to `emitted/`; an ambiguous pre-emission crash may replay the same
  stable ID, while model consumption after valid output is not acknowledged.
  Malformed hook input/state fails open (`0`, no stdout) and moves unsafe items
  to private quarantine with a private error marker rather than head-of-line
  blocking later tools.
- In `critic-note.sh --harness codex`, use `CRITIC_PROJECT_DIR` to atomically
  deposit a new immutable item for that exact allowlisted canonical project and
  session without overwriting older work. Derive `critique_id` from the reviewed
  snapshot plus summary, write via temp-file + `mv` under the same lock, reject
  symlink/non-owner/non-private state, and garbage-collect emitted/quarantined
  files older than seven days. Return `0` only after the item and parent
  directory are synced; a stable-ID retry must re-prove that durability before
  acknowledging the reviewed edit queue. Missing authorization or deposit
  failure is retryable and cannot fall through to a human-only success.
- In `critic-watch.sh`, derive `CRITIC_NOTE_ID` from the exact queue snapshot
  plus findings and export it only for the existing two-argument note-command
  invocation. Existing external delivery commands keep their argv contract and
  may ignore the new environment value.
- For Codex, native durable deposit is authoritative and happens before any
  optional custom injector/owner duplicate notification. Preserve custom
  injector pass-through for Claude and Hermes behavior.
- Enforce a 128 KiB hook-input cap and the locked 8 KiB/50-line summary cap
  with bounded/streaming reads before deposit; JSON-escape with `jq` and do not
  read the authoring transcript.
- Add `tests/codex-feedback-delivery.bats` covering no-pending silence, correct
  exit-0 JSON/schema, exact session isolation, stable-ID dedupe, two queued
  critiques with no overwrite, oldest-first emission, permitted same-ID replay
  after an ambiguous claim, invalid session/path rejection, malformed mailbox
  fail-open quarantine, hook/summary bounds, live-owner lease protection,
  dead-owner and reused-PID recovery, file/directory durability, 7-day cleanup,
  simultaneous writers/drainers under the real lock, bounded visible lock
  contention, exact-prefix queue acknowledgement, mode bits, atomic replace,
  and the former Codex log-and-skip false success.

**Red-first proof.**

Against a temporary checkout of parent commit `944c7ac^`, run the new test file
with the working-tree test copied in. At minimum, the model-visible delivery
and false-success cases must fail because the hook/script behavior is absent.
Record the case names and exit status in the Ledger; do not commit the red
checkout.

**Phase gate.**

```bash
bats tests/codex-feedback-delivery.bats \
  tests/shoulder-mode-harness.bats tests/shoulder-mode.bats
bash -n agents/release/critic-codex-feedback.sh \
  agents/release/critic-note.sh agents/release/critic-queue-lib.sh \
  agents/release/critic-watch.sh
bash scripts/leak-check.sh
git diff --check
```

Run the new hook once with a canned `PostToolUse` payload and read the actual
JSON with `jq -e`; then run it again and observe empty output.

**Observable DoD.** A Codex critique summary becomes valid hook JSON for only
its originating authorized project/session; immutable items remain durable
through one valid emission attempt with stable IDs and no overwrite; ambiguous
pre-emission failure replays, post-emission model consumption is honestly
unacknowledged, and unsafe state fails open into quarantine; focused gates pass.

**Delegation:** subagent — implement the mailbox writer/drainer and focused
red-first tests only; return ≤40 lines with files, red/green case names, exact
exit codes, and blockers.

### Phase 2 — Stop backstop and required-feedback state (2 pts)

**Slice.**

- Extend `critic-stop-gate-codex.sh` (sharing the mailbox helper where useful)
  to emit completed items with the exact Stop shape
  `{"decision":"block","reason":"Release critic [<id>]: ..."}`. Stop does not
  support PostToolUse `additionalContext`; its `reason` becomes the automatic
  continuation prompt.
- Read `[shoulder] require_feedback` from `<payload.cwd>/.agents/config.toml`
  with false as the only unset default. Invalid non-boolean values exit `2`
  with an actionable error. Preserve `CRITIC_BLOCK=1` compatibility and the
  existing unresolved `block|` finding behavior.
- For required feedback, add an urgent state keyed by hashes of
  `session_id`+`turn_id`. On the first Stop with a non-empty edit queue and no
  completed item:
  1. atomically write `tmp/critic-flush-<session-hash>`;
  2. make `critic-watch.sh` bypass idle/batch debounce for that session;
  3. poll the mailbox/status for at most 20 seconds; and
  4. if still pending, return one continuation reason telling Codex the release
     review is pending and that no completion claim is allowed.
- When `stop_hook_active = true`, poll once more for at most 20 seconds. Deliver
  all ready summaries within the 8 KiB cap if they arrived. If not, write a
  terminal state and return one final continuation reason:
  `Release critic unavailable (<budget|spawn|watcher|delivery|timeout>); stop
  all implementation and report this hard blocker to the user.` On the next
  Stop for the same turn, exit cleanly only if that hard-blocker continuation
  is the last assistant outcome. This bounds the hook at two continuations and
  prevents a hot loop.
- Teach the watcher to write per-session status for successful deposit, budget
  deferral, three-strike spawn failure, and delivery failure. In required mode,
  failure keeps the reviewed queue/snapshot recoverable; opportunistic/unset
  behavior remains today's behavior.
- Add focused cases for false/unset invariance, urgent debounce bypass, first
  20-second timeout (clock/sleep shimmed), completed finding continuation,
  second-stop terminal blocker for each status, third-stop bounded exit,
  clean completion, cross-session isolation, malformed state, concurrent flush
  and delivery, and the existing three stop-gate states.

**Red-first proof.** Run the new pending-queue and completed-mailbox Stop cases
against pre-change code and record their nonzero bats result before making the
working tree green.

**Phase gate.**

```bash
bats tests/codex-feedback-delivery.bats tests/shoulder-mode-harness.bats
bash -n agents/release/critic-codex-feedback.sh \
  agents/release/critic-stop-gate-codex.sh \
  agents/release/critic-stop-gate-lib.sh
bash scripts/leak-check.sh
git diff --check
```

Pipe canned Stop payloads through the real script for pending, delivered, and
clean states; read the returned JSON and exact exits.

**Observable DoD.** Required-feedback Codex either receives its completed
critic items before finishing or ends only after reporting a named release
hard blocker; urgent review bypasses debounce; the two-continuation ceiling
prevents a loop; unset behavior remains unchanged.

**Delegation:** subagent — implement the Stop state machine and focused tests;
return ≤40 lines with files, red/green cases, exact JSON/exits, and blockers.

### Phase 3 — Additive install, watcher unit, and honest doctor (3 pts)

**Slice.**

- Extend Codex wiring to add three idempotent entries without clobbering
  unrelated config: existing `apply_patch` capture, all-local-tool
  `PostToolUse` delivery, and `Stop` backstop.
- For an opted-in project, generate and enable
  `<project>-<release-display>-watch.service` with the canonical project as
  `WorkingDirectory`, `EnvironmentFile=-<project>/.agents/shoulder.env`,
  the shared `critic-watch.sh --project <project>` as `ExecStart`, and a safe
  restart policy. Re-running install must replace a legacy watcher definition
  and restart it only after `daemon-reload`.
- Extend `.agents/shoulder.env` with `CRITIC_PROJECT_DIR` and the configured
  `[shoulder] critic_harness`. Required-feedback remains a project config read
  by the Stop hook, not an implicit global default.
- Have the installed Codex hook write a non-secret runtime-seen marker carrying
  its schema/version and invocation timestamp. Doctor must distinguish
  `definition missing`, `configured but trust/runtime unverified since install`,
  and `executed since install`; TOML presence alone is never “active.” The
  runtime-seen marker is evidence only after a normal, non-bypass Codex process
  runs the exact definition.
- Extend doctor so any project declaring `[shoulder] auto_wire = true` or
  having an installed watch unit is checked for all three Codex hooks, env
  fields, the active unit's `EnvironmentFile`, canonical `ExecStart`, and
  active state. The captured Aurora legacy unit and configured-but-never-run
  hooks must fail doctor before repair.
- Keep install without shoulder opt-in byte-identical. Do not alter existing
  Claude/Hermes behavior. Parse and validate `[shoulder] harness` and
  `[shoulder] critic_harness` independently against
  `claude|codex|hermes`; invalid values exit `2`. The watcher receives
  `CRITIC_HARNESS` from `critic_harness`, while capture/delivery wiring uses
  `harness`.
- Extend `tests/shoulder-wire.bats` (and a focused unit fixture if clearer) for
  three-hook additive/idempotent wiring, unrelated hook survival, watcher unit
  generation, legacy-unit replacement, missing-hook/env/unit doctor failures,
  configured-but-runtime-unverified doctor failure, runtime-seen doctor success,
  unset invariance, all three valid authoring/reviewer selections, independent
  authoring-vs-reviewer selection, invalid-value exit `2`, and unchanged
  Claude/Hermes delivery contracts.
- Unit ownership is explicit: installer writes
  `~/.config/systemd/user/<project>-<release-display>-watch.service` through a
  temporary file and atomic rename, then `systemctl --user daemon-reload` and
  `enable --now`. Reinstall uses `try-restart` after the complete env and unit
  are in place. The rollback is the saved prior unit+env followed by
  `daemon-reload` and `restart`; a first install rolls back with
  `disable --now` plus removal of that exact unit only.

**Red-first proof.** On pre-change code, the three-hook, watcher
`EnvironmentFile`, and false-clean doctor cases must fail. Record names/exits.

**Phase gate.**

```bash
bats tests/shoulder-wire.bats tests/codex-feedback-delivery.bats \
  tests/shoulder-mode-harness.bats
bash -n install.sh agents/lib/shoulder-wire.sh \
  agents/release/critic-codex-feedback.sh \
  agents/release/critic-stop-gate-codex.sh
bash install.sh --project <fixture-project> --dry-run --wire-shoulder
bash install.sh --project <fixture-project> --doctor
bash scripts/leak-check.sh
git diff --check
```

Use a hermetic home/systemctl shim for focused tests. The orchestrator must also
read the real dry-run unit text before commit.

**Observable DoD.** Opt-in produces the complete definition surface and a
watcher that actually sources its env; doctor stays red until a normal Codex
process executes the configured hook after install; the captured legacy shape
is red; unset install is unchanged; focused gates pass.

**Delegation:** subagent — implement installer/doctor/unit wiring and focused
red-first tests without modifying real user config or systemd; return ≤40
lines with files, cases, generated-unit evidence, exits, and blockers.

### Phase 4 — Fleet-live install and real fresh-Codex proof (inline, 0 pts)

**Slice.**

- Run the complete Shipyard gate battery before changing live user config or
  units. Commit and push the verified Shipyard implementation on `main`;
  remember that `agents/**` and `install.sh` are fleet-live.
- In Aurora's `.agents/config.toml`, set the explicitly approved shoulder
  values:

  ```toml
  [shoulder]
  auto_wire = true
  harness = "codex"
  critic_harness = "codex"
  require_feedback = true
  ```

  Preserve any existing section and comments. Run Shipyard install with
  `--wire-shoulder`, inspect the exact three new Codex hook definitions, reload
  user systemd, and verify the Aurora watch service is active. At this point
  doctor must honestly report the expected trust/runtime-unverified state; it
  becomes clean only after the normal trusted hook proof below.
- Save the exact prior Aurora watcher unit/env/config and the user Codex config
  under ignored `tmp/` before install; write the corresponding rollback command
  into the Ledger. Never print config secrets.
- Do not assume the current Codex process reloads hooks. Start a fresh
  interactive Codex process, open `/hooks`, inspect the three Shipyard
  definitions and their source, and trust those exact hashes. Exit and start a
  second fresh **normal process without bypass**; its runtime-seen marker is the
  trust proof and must make doctor clean.
- Split model visibility from stochastic critic content:
  1. Deterministic path — atomically seed one pending item containing a random
     non-secret nonce, run a real fresh normal Codex local tool, and require its
     output to repeat the stable critique ID+nonce it received as developer
     context.
  2. Real critic path — start a bounded deterministic watcher probe
     (`CRITIC_IDLE_SEC=0`, short poll, real `CRITIC_HARNESS=codex`), have the
     same fresh authoring session make a disposable edit, and observe capture,
     a real `release.critique` event, durable mailbox deposit, and consumption
     in that same session. The critic may legitimately return zero findings;
     the delivered summary and ID are the acceptance evidence.
- An isolated `--dangerously-bypass-hook-trust` run may be used before the
  normal proof to debug vetted hook JSON, but it cannot satisfy the trust or
  final live gate.
- Observe all state transitions: `critic-queue-<session>`, urgent flush/status
  if Stop is exercised, `release.critique`, pending→claim→emitted, and the fresh
  Codex output explicitly acknowledging `Release critic [<id>]`. A human
  notification is not evidence.
- Remove only the disposable probe edit/artifacts, stop the bounded probe, and
  confirm no orphaned Codex/watcher process. Leave the installed Aurora watcher
  active. Preserve the paused ticket 043 working tree exactly.
- Record the live commands and redacted evidence in `.agents/gates.md` Traps
  and the ticket Ledger. Do not track a machine path, session id, or secret.

**Phase gate.**

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
bash scripts/ticket-lifecycle.sh --project . --check
./install.sh --doctor --project .
./install.sh --doctor --project <aurora-project>
systemctl --user is-active <aurora-project>-<release-display>-watch.service
git diff --check
```

Run `node scripts/check-deck-render.mjs`; exit `3` is the documented skip. Run
`python3 scripts/delegation-report.py` and verify every phase has its matching
Ledger builder line. Check CI after push. Graduate this ticket with
`scripts/ticket-lifecycle.sh --project . --graduate <ticket>` only after the
fresh-session proof and full battery pass.

**Observable DoD.** A fresh normal trusted Codex session editing Aurora
receives the real cold release critic's same-session model-visible summary;
the deterministic nonce separately proves context visibility; Aurora doctor
and watcher are healthy; no probe process/artifact remains; the paused Aurora
work is unchanged; Shipyard is clean, pushed, and CI-green.

**Delegation:** inline (the orchestrator must personally inspect and authorize
the fleet-live unit/config change, observe the fresh Codex model context, run
the gates, clean up processes, and verify repository state).

## Ledger

Append before each phase: the slice plan, `builder:` line, red-first evidence,
verification outputs, commit hash, and any default applied. Never record a
secret, machine-specific home path, or raw session identifier.

### Phase 1 — complete

- **Plan:** add the immutable per-session feedback mailbox, stable critique
  IDs, atomic/capped Codex note deposit, model-visible PostToolUse drain, and
  red-first concurrency/recovery coverage. Preserve all non-Codex delivery
  behavior.
- **builder:** subagent (2 builders + 1 cold reviewer)
- **Baseline:** combined cross-platform `main` is clean; `bats tests/` passed
  523/523; syntax, Python compile, leak, deck freshness/completeness, lifecycle,
  doctor, and diff checks all exited 0.
- **Red-first:** the new model-visible delivery and former false-success cases
  failed against the pre-change behavior. Later critic-driven regressions also
  failed before remediation: oversized hook input timed out, deposit ignored a
  simulated sync failure, a writer lost an edit after more than one second of
  lock contention, and a reused process ID pinned stale queue/mailbox locks.
- **Verification:** root rerun `bats tests/codex-feedback-delivery.bats
  tests/shoulder-mode-harness.bats tests/shoulder-mode.bats` at 74/74, the
  phase shell syntax sweep exited 0, leak-check was clean, and working/cached
  diff checks exited 0. Eight repeated concurrent-writer stress passes were
  green. The cold final diff audit reported no Phase-1 blocker.
- **Real critic proof:** a real Codex release critic produced findings from the
  queued diff and the feedback hook returned those findings as valid
  `PostToolUse.additionalContext` JSON in the active Codex session. A second
  drain emitted no duplicate.
- **Defaults applied:** O1 mailbox/state limits and O2 all-local PostToolUse
  boundary exactly as recorded above.
- **Integration correction:** the final full-suite pass exposed a shell-owner
  race that the earlier focused stress had not triggered: one Bash execution
  shape reported a short-lived helper PID. The portable path now uses
  `BASHPID` when available and a foreground-child parent probe on stock macOS
  Bash 3.2. Direct disappearing-process and Bash-3.2-fallback cases are green.
- **Commit:** integrated implementation commit
  `19abfe27ca8008187c61157046637b9295aebb19`. The phase was not committed
  independently because the pre-Phase-3 fresh-install authorization gap made
  that intermediate tree unreleasable.

### Phase 2 — complete

- **Plan:** add the crash-safe Stop claim/commit/rollback path, bounded
  required-feedback state machine, urgent watcher bypass, per-session status,
  and exact cleanup for completed and clean paths.
- **builder:** subagent (Stop state machine and focused tests)
- **Red-first:** the completed-mailbox and first-required-Stop cases failed
  0/2 with exit `1` against pre-change behavior; both produced empty legacy
  output and `jq` exit `4`.
- **Verification:** the required focused matrix passed 72/72. Pending,
  completed, terminal, and clean canned Stop payloads all returned their exact
  documented JSON/exit shapes. Invalid `require_feedback` and non-boolean
  `stop_hook_active` payloads exit `2`. Maximum-size summaries emit whole;
  abandoned pre-emission claims replay the same stable ID; later ready items
  remain pending rather than being partially acknowledged.
- **Hardening:** state, flush, and status files clear on success; state reads
  require owner, mode `0600`, and link count `1`; required-mode budget, spawn,
  and delivery failures preserve the reviewed queue.
- **Commit:** integrated implementation commit
  `19abfe27ca8008187c61157046637b9295aebb19`.

### Phase 3 — complete

- **Plan:** provision the exact three-hook Codex bundle, project
  authorization, independent author/reviewer harnesses, systemd-compatible
  env, atomic watcher replacement/rollback, runtime proof, and loaded-unit
  doctor checks.
- **builder:** subagent (installer, doctor, unit wiring, and focused tests)
- **Red-first:** the original seven hook/env/unit/doctor cases failed with
  exit `1`; rollback and stale-loaded-unit cases also failed before their
  respective fixes.
- **Verification:** `tests/shoulder-wire.bats` passed 19/19 and the combined
  Phase-3 matrix passed 91/91. The hermetic dry-run exited `0`, printed the
  complete `WorkingDirectory`, `EnvironmentFile`, `ExecStart`, restart, and
  `WantedBy` surface, and left config/env/unit checksums unchanged. Syntax,
  leak, and diff gates passed.
- **Hardening:** TOML parsing falls back from `tomllib` to `tomli`; wrapper
  input is capped at 128 KiB; runtime state is private and rejects hardlinks;
  env/unit writes are target-adjacent atomic renames; activation failure
  restores the exact prior env/unit and loaded service. Doctor queries the
  loaded unit as well as its file, so a repaired file with a stale active
  definition remains red.
- **Commit:** integrated implementation commit
  `19abfe27ca8008187c61157046637b9295aebb19`.

### Integrated release gates — complete

- **Plan:** independently audit the merged production/test surface, remediate
  findings, and run the complete repository battery before any fleet-live
  change.
- **builder:** inline (the orchestrator must read the cold findings and every
  release-gate result itself)
- **Cold review:** three fresh read-only Codex critics audited bounded
  mailbox, queue/watcher, and install/Stop batches. They found a
  symlink-followable watcher-status temporary name and string-vs-boolean Stop
  validation; both were fixed with targeted green cases. A cross-file
  follow-up returned `AUDIT_RESULT=NO_BLOCK`. The apparent missing
  authorization finding was a batching artifact and the installer batch
  confirmed the exact allowlist provisioning path.
- **Verification:** `bats tests/` passed 659/659. The full shell syntax sweep,
  Python compile, leak firewall, deck freshness, deck completeness, deck DOM
  render, lifecycle check, Shipyard doctor, delegation report, and diff check
  all exited `0`.
- **Commit:** `19abfe27ca8008187c61157046637b9295aebb19`,
  canonical identity verified with the Codex co-author trailer.

### Phase 4 — complete

- **Plan:** preserve the exact prior Aurora config/unit/env/Codex config,
  enable the approved Codex/Codex required-feedback configuration, install the
  trusted three-hook bundle and watcher, then prove deterministic nonce
  visibility and one real cold-critic round trip in fresh normal Codex
  sessions. Clean only bounded probe state and leave the watcher active.
- **builder:** inline (fleet-live authorization, process observation, rollback
  custody, and model-context proof cannot be delegated)
- **Pre-live gate:** the integrated implementation was pushed and its first CI
  run passed every job. Before the live install, the exact prior Aurora
  project config, user Codex config, watcher unit/state, authorization state,
  tracked diff, untracked contents, and service state were recorded in a
  private rollback bundle.
- **Normal-process trust proof:** the installed Codex `/hooks` view showed all
  three exact hooks active after explicit trust. A second fresh normal
  `codex exec` process exercised a local tool without bypass flags; Shipyard
  Doctor then reported the hook runtime as executed and the Aurora install as
  clean.
- **Deterministic context proof:** a fresh Codex process exposed its real
  session ID, a random same-session nonce was deposited while its local tool
  was active, and the next model turn echoed both the stable feedback ID and
  nonce. The mailbox moved once from pending to emitted.
- **Real cold-critic proof:** a separate fresh normal Codex author created one
  disposable unsafe research note. The real Codex release critic emitted one
  block across one file (21,428 tokens), durably deposited it, and the same
  authoring session echoed the exact 64-character critique ID and summarized
  the privileged-credential finding. The mailbox finished at pending `0`,
  emitted `1`; the edit queue was consumed exactly once.
- **Live-discovered transport correction:** the first real critic attempt
  reproduced exit `126`: Aurora's historical branch delta was 1.6 MiB and the
  dispatcher passed it as one argument, above Linux's per-argument limit. A
  direct 200,000-byte repro failed before exec. Streaming fixed transport but
  exposed Codex's separate 1,048,576-character model-input ceiling. The final
  repair streams oversized Claude and all Codex prompts, fails oversized
  unsupported Hermes calls with a bounded diagnostic, and scopes shoulder
  review to exact queued paths with cross-harness-safe bounded sections.
- **Retry and scope hardening:** required-mode three-strike spawn/delivery
  exhaustion is persisted per immutable queue/Stop generation, so the watcher
  cannot restart an infinite three-attempt loop; later queued work reopens the
  retry path. Cached delivery preserves the original reviewed-file count.
  Staged deletions remain reviewable, Git pathspec magic is literal, hunk-safe
  annotation uses the full scoped diff before prompt bounding, and UTF-8
  truncation cannot split a code point. The critic role now states the queued
  batch and explicit omission/tool-inspection contract.
- **Verification:** every live-discovered case was demonstrated red first.
  The final focused delivery/harness matrix passed 135/135 and `bats tests/`
  passed 668/668. Shell syntax, Python compile, leak firewall, deck freshness,
  deck completeness, rendered deck, lifecycle, Shipyard Doctor, delegation
  report, and diff checks passed. The final independent cold review returned
  `NO_BLOCK`; Aurora Doctor reports a clean install and its watcher is active
  and enabled.
- **Cleanup and preservation:** all disposable files, processes, per-session
  queue/Stop state, and proof mailbox content were removed. Aurora ticket 043's
  tracked diff matches the pre-live hash byte-for-byte, and all pre-existing
  untracked source/data content matches after excluding only the approved new
  shoulder environment and the live release audit event files. The approved
  shoulder config/env remain installed; no optimizer code was changed.
- **Commit:** the live transport/scope correction and this graduation ride in
  the final Phase-4 commit. The pushed CI run must be green before owner
  notification and Aurora work resume.

### Follow-up — dual-model pull-request release gate

After this blocker and Aurora ticket 043, scope a separate feature for
independent Claude+Codex pull-request reviews whose findings are posted as
attributed GitHub PR comments. That ticket must define spend caps, duplicate
finding reconciliation, disagreement/escalation behavior, required-vs-advisory
merge status, comment update/idempotence, and failure behavior when only one
reviewer completes. It is deliberately not part of this live shoulder-delivery
repair.

Also consider streaming exact-prefix comparison/copy for unusually large edit
queues. Phase 1 keeps the queue lock bounded and fail-open, but the current
prefix operation reads the reviewed queue into memory; this is a hardening
follow-up, not a correctness blocker for the present small queue contract.

## Definition of Done

- [x] A regression test fails against pre-change `main` on the captured defect
      and passes with the fix.
- [x] Codex findings are durably keyed to the authorized canonical project and
      originating session through one valid hook emission, with stable IDs and
      no overwrite; ambiguous pre-emission recovery may replay, while
      post-emission model consumption is explicitly unacknowledged.
- [x] Stop either delivers required feedback or causes the authoring Codex to
      report a named hard blocker within the two-continuation ceiling.
- [x] A failed model-delivery attempt remains retryable; a human alert or log
      does not acknowledge model delivery.
- [x] Opt-in install wires the full Codex path and its watcher; unset install is
      unchanged.
- [x] Doctor fails on the live defect shape and passes only after capture,
      delivery, stop, env, watcher wiring, and a post-install normal Codex hook
      execution are all real.
- [x] The Shipyard automated gate battery is green with red-first coverage for
      the defect and its former coverage gap.
- [x] A fresh Codex live run in Aurora observes a release-critic finding as
      model-visible context in the same session.
- [x] Shipyard is clean after its final commit; Aurora's pre-existing ticket 043
      tree is preserved except for the approved shoulder config/runtime and
      live audit events; affected user services are active.

Build with `execute-ticket`.
