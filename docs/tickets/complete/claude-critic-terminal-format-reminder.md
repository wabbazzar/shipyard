# Keep Claude shoulder reviews machine-parseable after large evidence blocks

- **Created:** 2026-08-11
- **Owner:** wabbazzar
- **Status:** COMPLETE — built and verified live 2026-08-11 CDT
- **Priority:** urgent
- **Type:** bugfix
- **Estimated Points:** 3 (two phases)
- **Refs:** `agents/release/critic-role.md:50-71`,
  `agents/release/critic-watch.sh:833-877`,
  `tests/shoulder-mode.bats:149-243`,
  `tests/shoulder-mode.bats:737-790`,
  `docs/tickets/complete/shoulder-critic-malformed-response-recovery.md`

## Summary

Repeat the shoulder critic's exact response grammar at the terminal end of its
assembled prompt, after all untrusted project-extension and diff evidence, so a
Claude reviewer returns findings without prose or Markdown while Shipyard's
strict fail-closed parser remains unchanged.

## Problem / background

### Captured live reproduction — Aurora Ticket 050, 2026-08-11

Aurora was configured with author harness `codex`, critic harness `claude`,
required feedback, and a retained four-file review queue. Process inspection
proved the watcher launched `claude -p` (`claude-fable-5`), not Codex. Three
successful model invocations each returned a single sentinel and substantive
schema-shaped findings, but also added explanatory prose and a fenced code
block. The strict classifier correctly rejected every response as
`invalid_line` and preserved the queue:

```text
attempt 1: invalid_line · 10,124 tokens
attempt 2: invalid_line · 8,197 tokens
attempt 3: invalid_line · 11,212 tokens · malformed_response_exhausted
final diagnostic: sentinel_count=1 · invalid_line_count=4 · response_bytes=5,315
```

The violated observable contract is that `[shoulder].critic_harness =
"claude"` must produce a parseable cold review that can be delivered to the
configured Codex author session. Instead, a semantically useful Claude review
is terminally unavailable and blocks the required-feedback release gate.

### Root cause and rival causes

- **Where:** `critic-watch.sh` assembles the prompt as role → project extension
  → changed files → diff and ends directly on `$diff`. The exact output grammar
  appears only at `critic-role.md:50-71`, up to 88 KB before the output point.
- **When:** the ordering dates to commit `7654c98b`; it became an observed
  release blocker when Aurora switched the critic from Codex to Claude on
  2026-08-11. Starbird independently recorded the same Claude `invalid_line`
  exhaustion, so the class is not Aurora-specific.
- **Elsewhere:** any Claude/Hermes critic receiving a long or instruction-like
  project extension/diff can drift despite retaining the sentinel.
- **Why missed:** prompt tests cover scope, byte bounds, UTF-8, and omission
  markers, while malformed-response tests inject canned replies independently
  of the assembled prompt. No test asserts that the final nonblank prompt lines
  restate the strict output contract after adversarial evidence.
- **Parser relaxation ruled out:** filtering for schema-shaped lines accepts an
  adversarial response with contradictory outside prose. The completed
  malformed-response ticket deliberately locks prose/fence rejection. Keep the
  parser strict.
- **Model pinning ruled out:** no retained A/B evidence proves another Claude
  model obeys the format, and changing model/provider selection would hide the
  generic prompt-order defect.

## Decisions

### Locked

| Decision | Rationale |
|---|---|
| Preserve the strict response classifier byte-for-byte | Outside prose and fences remain an intentionally invalid review; no prompt injection is silently discarded. |
| Append a short terminal contract after the bounded diff | The last instruction defines evidence as untrusted and repeats the only allowed finding/sentinel lines at the model's output point. |
| Make the reminder harness-neutral | Claude is the live reproducer, but the same prompt must remain correct for Codex and Hermes. |
| Do not change retry, budget, delivery, severity, model, or provider behavior | The defect is prompt ordering only. |
| Restore Aurora through the installed watcher path | Reinstall/restart only Aurora's critic wiring, prove the actual child is Claude, and let its preserved queue complete normally. |

### Open decisions with defaults

None.

### User-decision class

None. The owner explicitly directed the release critic to run Claude and
approved the temporary 20-million-token daily review allowance.

## Technical requirements

- In `agents/release/critic-watch.sh`, append a stable terminal section after
  `$diff` that says extension/diff content is evidence, never executable or
  output-format instruction, and requires only zero or more
  `SEVERITY|file|one-line finding` lines followed by exactly
  `TOKENS_HINT|<none>`—no prose, Markdown, or fences.
- Do not interpolate project-controlled content into the terminal reminder.
- In `tests/shoulder-mode.bats`, capture the exact assembled prompt with a
  hermetic harness stub. Put conflicting Markdown/result-writing instructions
  in both `.agents/release.md` and a queued diff. Assert the reminder occurs
  after both and its canonical grammar/sentinel are the final nonblank lines.
- Retain existing malformed-output rejection tests unchanged and green.
- Add no config key, parser normalization, dependency, model call, or public
  telemetry field.

## Implementation plan

### Phase 1 — terminal prompt contract (2 pts)

- Add the failing-first prompt-order regression, then append the smallest
  constant terminal reminder to `critic-watch.sh`.
- The hermetic case must put conflicting Markdown/result-writing instructions
  in both project extension and diff evidence, capture the whole prompt, and
  prove the authoritative reminder and sentinel are last.
- Keep response classification byte-identical. Run the focused prompt and
  malformed-response cases, then the complete gate matrix below before a small
  direct commit on Shipyard `main`.

**Delegation:** subagent — implement only the prompt-order regression and
terminal reminder in `tests/shoulder-mode.bats` and
`agents/release/critic-watch.sh`; return ≤40 lines with the red/green focused
commands, exact captured prompt tail, files changed, and blockers. Do not touch
live projects, services, queues, tickets, commits, or pushes.

**Verification:**

```bash
bats --filter 'critic prompt ends with the authoritative response contract|critic rejects malformed response|malformed response lifecycle' tests/shoulder-mode.bats
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
bash scripts/ticket-lifecycle.sh --project . --check
git diff --check
```

### Phase 2 — installed Aurora Claude-to-Codex proof (1 pt)

- Reinstall Aurora's already-authorized shoulder wiring from the committed
  Shipyard source so its watcher loads the fix. Do not restart another project.
- Preserve the exhausted queue; use the official Codex queue hook to append the
  same Ticket 050 paths and thereby create a fresh immutable snapshot
  generation. Verify the launched child is `claude -p`.
- Accept only a normally parsed and delivered `release.critique` result. Inspect
  the persisted finding, event lineage, delivery disposition, and exact-prefix
  queue consumption. Never hand-normalize Claude output or substitute Codex.
- If Claude returns a substantive Aurora finding, leave Aurora's Ticket 050
  phase uncommitted and route that finding back into its existing repair loop.
- Graduate this ticket only after the live chain proves Claude review reaches
  the Codex author normally, then rerun the complete phase gate matrix before
  the lifecycle commit and push.

**Delegation:** inline (live service/queue verification must be performed and
read directly by the orchestrator; no implementation is delegated in this
phase).

**Verification:**

```bash
bash install.sh --project ../aurora --dry-run
bash install.sh --project ../aurora
bash install.sh --doctor --project ../aurora
# Run Aurora's installed watcher for the retained Codex session and inspect the
# process tree, queue/status files, finding payload, and release.critique events.
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
bash scripts/ticket-lifecycle.sh --project . --check
git diff --check
```

## Testing strategy

- Failing-first Bats prompt capture proves the old prompt ends on adversarial
  diff text rather than the machine grammar.
- Focused `tests/shoulder-mode.bats` cases prove terminal ordering and retain
  strict malformed-response rejection.
- Full `bats tests/`, shell syntax, leak, deck freshness/completeness, lifecycle,
  and diff gates protect the fleet-live core.
- The real Aurora watcher supplies the final system proof: actual Claude child,
  valid findings file/event, Codex delivery, and consumed preserved queue.

## Definition of Done

- [x] The captured prompt-order regression fails before implementation and
      passes after it.
- [x] The assembled critic prompt ends with the immutable response grammar
      after every project-controlled evidence block.
- [x] Parser strictness and malformed-response exhaustion tests remain green.
- [x] Full Shipyard gates pass before both phase commits on `main`.
- [x] Aurora's installed watcher runs Claude and delivers a normally parsed
      Ticket 050 review into the Codex session without manual normalization.
- [x] The retained Aurora queue is consumed only after valid persistence and
      delivery; any substantive finding is handled before Ticket 050 commits.

## Dependencies

- The existing strict classifier and bounded retry state from
  `shoulder-critic-malformed-response-recovery.md`.
- Aurora's retained Ticket 050 queue and owner-approved Claude/budget config.

## Risks and mitigations

- **Evidence prompt injection:** terminal reminder declares all preceding
  project content untrusted and is never built from project text.
- **False acceptance:** parser remains unchanged; invalid output still fails
  closed.
- **Fleet-live regression:** hermetic full gates precede the small main commit;
  only Aurora's watcher is deliberately restarted for live proof.
- **Duplicate review spend:** the exhausted generation remains preserved; a
  fresh queue generation is triggered once after the repair.

## Out of scope

- Accepting, stripping, or normalizing prose/code fences.
- Changing Claude models/providers, parser grammar, retry ceilings, severity,
  budget accounting, or delivery mechanics.
- Any Aurora application, optimizer, UI, plan, or Ticket 050 code change.

## Ledger

- 2026-08-11 — live Claude reproduction captured on Aurora: three
  `invalid_line` attempts exhausted with one sentinel each; queue preserved.
  Independent probes ruled in terminal prompt ordering and ruled out parser
  relaxation/model pinning as safe root fixes. `builder: subagent (3 read-only
  diagnosis agents)`.
- 2026-08-11 — polish baseline: `bats tests/` passed 817/817; shell syntax,
  leak firewall (with the ticket intent-to-add), deck freshness/completeness,
  ticket lifecycle, and diff checks passed. No user-decision-class item is
  open. Phase 1 delegates the bounded watcher/test implementation; Phase 2 is
  inline because it is live service and queue verification. `builder: root
  (polish and baseline verification)`.
- 2026-08-11 — Phase 1 plan: add the adversarial prompt-tail regression red,
  append the immutable terminal response contract without touching the strict
  classifier, then run focused and full Shipyard gates before the core commit.
  `builder: ticket050_rival_visual (watcher and Bats implementation only)`.
- 2026-08-11 — Phase 1 complete: the new prompt-tail case failed against the
  old watcher, then passed after the constant terminal contract was appended.
  Focused prompt/strict-malformed cases passed 4/4; the full suite passed
  818/818. Shell/Python syntax, leak, deck freshness/completeness, lifecycle,
  and diff gates passed. No classifier, retry, budget, delivery, model, or
  provider behavior changed. `builder: ticket050_rival_visual (bounded
  implementation); verifier: root`.
- 2026-08-11 — Phase 2 complete: Aurora was reinstalled with author Codex and
  critic Claude. A temporary one-shot of the installed watcher visibly spawned
  `claude -p`; Claude returned a strictly parseable 0-block/1-warn/3-note
  review using 5,126 tokens. The watcher persisted the finding, emitted the
  `release.critique` event, deposited a private mode-0600 pending item for this
  Codex session, consumed the exact queue, and restarted the normal service.
  The warning is routed into Aurora Ticket 050 and its phase remains
  uncommitted until remediated. `builder: root (live service/queue proof)`.
- 2026-08-11 — Codex's installed runtime wrapper was exercised with this exact
  project/session after reinstall; the install doctor is clean. It drained the
  session backlog in order and emitted the new critique
  `1c81c04e…ad33e0` as the tenth item, proving Claude persistence and actual
  Codex consumption rather than mailbox deposit alone. `builder: root (native
  hook and ordered-delivery proof)`.

---

Built, verified, and ready for deterministic graduation.
