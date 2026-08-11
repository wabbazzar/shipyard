# Eliminate Claude critic review preambles

- **Created:** 2026-08-11
- **Owner:** wabbazzar
- **Status:** POLISHED — executable; no open owner decision
- **Priority:** urgent
- **Type:** bugfix
- **Estimated Points:** 2 (two phases)
- **Refs:** `agents/release/critic-watch.sh`, `tests/shoulder-mode.bats`,
  `docs/tickets/complete/claude-critic-terminal-format-reminder.md`

## Summary

Make the critic prompt's terminal contract explicitly forbid a review-summary
preamble and require the first output byte to begin a valid lowercase finding
or the sentinel. Keep the response parser strictly fail-closed.

## Captured reproduction and root cause

The first terminal-reminder repair produced one successful live Claude review,
but Aurora Ticket 050's next immutable generation exhausted all three retries.
Every response contained exactly one sentinel, valid finding lines, and exactly
one invalid preamble:

```text
attempt 1: “Reviewed the queued batch …”
attempt 2: “block-free on the queued batch itself …”
attempt 3: “SEVERITY findings verified …”
```

The queue remained preserved after 7,284 and 13,104 tokens on the first two
attempts and the third terminal exhaustion. The terminal reminder still ends
with the abstract `SEVERITY|file|one-line finding` placeholder and does not say
what the first byte must be or explicitly ban review announcements. Claude
therefore follows the findings grammar but prepends one summary line.

The violated contract is that a configured Claude critic must produce a
machine-parseable review within the bounded retry policy. The coverage gap is
that the prompt-tail regression asserts ordering and generic “no prose” words,
but not an explicit first-byte allowlist, literal-placeholder ban, preamble ban,
or stop-after-sentinel rule.

## Locked decisions

- Do not strip, normalize, or ignore a preamble; arbitrary outside prose remains
  indistinguishable from prompt injection.
- Do not change the classifier, retry/budget/delivery behavior, model, provider,
  or harness.
- Replace the ambiguous placeholder-only tail with concrete lowercase start
  forms, an explicit announcement/preamble ban, and an immediate stop rule.
- Restore Aurora only through its installed Claude-critic/Codex-author path and
  accept only a normally parsed and delivered review.

## Phase 1 — precise terminal grammar (1 point)

Add a failing-first hermetic assertion that the terminal contract:

- requires the first output byte to start `block|`, `warn|`, `note|`, or
  `TOKENS_HINT|<none>`;
- says never to output the literal placeholder `SEVERITY`;
- forbids announcing/summarizing the review, coverage, checks, or scope; and
- requires an immediate stop after the single sentinel.

Then make the smallest constant prompt-tail edit. Preserve all parser tests.

**Files:** `agents/release/critic-watch.sh`, `tests/shoulder-mode.bats`, this
ticket.

**Delegation:** subagent — own only watcher/test implementation; produce the
focused red/green result and exact prompt tail; no live project, ticket, commit,
push, parser, model, retry, budget, or delivery changes.

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

## Phase 2 — repeated live Claude proof (1 point)

Commit Phase 1 on Shipyard `main`, reinstall only Aurora, create a fresh Ticket
050 queue generation through the official Codex hook, and run the installed
watcher with Claude. Require a normally parsed review and native Codex delivery.
Any substantive Aurora finding returns to Ticket 050; another preamble reopens
this ticket rather than weakening the gate. Graduate, rerun full gates, commit,
and push only after the live chain passes.

**Delegation:** inline (live service/queue verification must be performed and
read directly by the orchestrator).

**Verification:** reinstall/doctor Aurora through `bash install.sh --project
../aurora`, inspect the actual Claude child and Codex feedback item, then rerun
the complete Phase 1 command matrix before graduation and the lifecycle commit.

## Definition of Done

- [ ] Prompt regression fails before and passes after the suffix edit.
- [ ] Terminal contract names concrete valid first bytes and bans preambles,
      literal `SEVERITY`, text after the sentinel, Markdown, and prose.
- [ ] Strict malformed-response behavior remains unchanged and green.
- [ ] Full Shipyard gates pass before both commits.
- [ ] Aurora's installed Claude critic returns a normally parsed Ticket 050
      review and Codex consumes it through the native runtime wrapper.

## Out of scope

Parser normalization; response filtering; more retries; model/provider pins;
Aurora application changes; acceptance of any rejected response.

## Ledger

- 2026-08-11 — three retained live Claude responses independently reproduced
  the same one-preamble/one-sentinel failure; parser relaxation and retry are
  ruled out. Phase 1 is delegated; Phase 2 is live inline verification.
  `builder: root (reproduction and polish)`.
- 2026-08-11 — pre-edit baseline remains the immediately preceding clean
  Shipyard proof: 818/818 Bats plus syntax, leak, deck, lifecycle, and diff
  gates. The new ticket is intent-to-add so leak-check reads it. `builder: root
  (baseline verification)`.
- 2026-08-11 — Phase 1 complete: the first-byte/preamble regression failed
  against the prior reminder, then passed after the constant tail named the
  four concrete lowercase starts, banned literal `SEVERITY` and review
  announcements, and required an immediate stop after the sentinel. Focused
  prompt/malformed tests passed 4/4; full Bats passed 818/818; syntax, leak,
  deck, lifecycle, and diff gates passed. Parser/retry/budget/model/delivery
  code is unchanged. `builder: ticket050_rival_visual; verifier: root`.

---

Polished and ready for `execute-ticket`.
