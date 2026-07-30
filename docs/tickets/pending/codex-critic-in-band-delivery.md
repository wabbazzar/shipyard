# Deliver release-critic findings into the authoring Codex session

- **Created:** 2026-07-30
- **Owner:** wabbazzar
- **Status:** Draft
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

1. A completed Codex critique is persisted atomically for its originating
   `session_id`; findings for one session cannot leak into another.
2. A Codex hook at the next supported local-tool boundary drains that pending
   item exactly once and returns concise model-visible `additionalContext`.
3. The final-turn path cannot silently lose a pending critique. A Codex `Stop`
   hook must deliver an already-completed finding and, when feedback is
   required for that project/session, keep the turn alive while captured work
   still awaits critique.
4. Capture, critique, mailbox deposit, model delivery, and acknowledgement are
   distinct states. The watcher may clear the edit queue after a durable
   mailbox deposit; it must not equate a human alert or log-and-skip with
   model delivery.
5. Missing, malformed, stale, or raced mailbox files fail safely without
   corrupting another session. Finding size is capped, content is JSON-escaped,
   and no transcript or secret is copied into tracked files.
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
| D2 | Delivery is asynchronous and same-session: persist by Codex `session_id`, then surface on the next local-tool boundary with a Stop backstop. |
| D3 | A human alert is an optional duplicate notification, never proof of Codex delivery. |
| D4 | Install remains opt-in; unset behavior stays byte-for-byte equivalent. |
| D5 | The full acceptance gate uses a fresh Codex process because a running process may not reload newly trusted hook definitions. |

### Open with defaults

| # | Question | Default |
|---|---|---|
| O1 | Mailbox storage shape | One atomically written file per project and Codex session under the project's ignored `tmp/` directory, with a claim/ack transition. |
| O2 | Hook boundary | Drain on all supported local `PostToolUse` events; use `Stop` for final-turn delivery/pending-work continuation. |
| O3 | Required-feedback policy | Add an explicit shoulder setting; unset remains note-only, while Aurora enables required feedback for the repair and resumed ticket. |

### User-decision class

None open. The owner explicitly paused all other work and approved repairing
and proving this live automation first.

## Implementation plan

### Phase 1 — Pin the failing contract and state machine

Add a deterministic regression that fails on current `main` and describes the
capture, critique, durable pending delivery, same-session model context, and
acknowledgement states. Cover cross-session isolation and the existing
log-and-skip false-success.

Delegation: subagent — implement only the hermetic red-first regression and
state-transition fixtures; return files, failing cases, and exact exit codes.

### Phase 2 — Add durable Codex feedback delivery

Implement the per-session pending mailbox and Codex hook response. Preserve
the existing asynchronous watcher and budget behavior. Ensure an undelivered
finding remains recoverable, exact-once from the model's perspective, bounded,
and safely escaped.

Delegation: subagent — implement the mailbox writer/drainer and focused tests
against the pinned state machine.

### Phase 3 — Wire install, doctor, and final-turn backstop

Additively install the Codex delivery hook and Stop backstop, make the watcher
consume the generated shoulder environment, and make doctor detect the actual
active-path drift. Preserve opt-in/unset invariance.

Delegation: subagent — implement installer/doctor/service wiring and focused
tests without touching live configuration.

### Phase 4 — Live install and end-to-end Codex proof

Install the verified Shipyard change for Aurora, explicitly enable required
feedback, and run a fresh Codex edit through capture, a deterministic watcher
trigger, cold critique, and model-visible delivery. Record the actual evidence,
then run the complete Shipyard gate battery and leave the watcher active and
healthy.

Delegation: inline (the orchestrator must personally verify the live service,
fresh Codex session, event stream, and final repository state).

## Definition of Done

- [ ] A regression test fails against pre-change `main` on the captured defect
      and passes with the fix.
- [ ] Codex findings are durably keyed to the originating session and surfaced
      exactly once as model-visible hook context.
- [ ] Stop cannot silently finish a required-feedback session while its edit
      queue or completed finding is pending.
- [ ] A failed model-delivery attempt remains retryable; a human alert or log
      does not acknowledge model delivery.
- [ ] Opt-in install wires the full Codex path and its watcher; unset install is
      unchanged.
- [ ] Doctor fails on the live defect shape and passes only after capture,
      delivery, stop, env, and watcher wiring are all real.
- [ ] The Shipyard automated gate battery is green with red-first coverage for
      the defect and its former coverage gap.
- [ ] A fresh Codex live run in Aurora observes a release-critic finding as
      model-visible context in the same session.
- [ ] Shipyard and Aurora are left clean and their affected user services are
      active; ticket 043 remains paused until this checklist is complete.

Build only after this ticket is polished with `polish-ticket`.
