# Wiring the skills into the crew runners

The two ticket skills are meant to be invoked **by the crew, headless**, not
only by a human in-session. The intended wiring:

- **build (helldiver)** invokes **`execute-ticket`** for a ratified ticket —
  once a proposal is approved and hardened into `<project>/docs/tickets/`, the
  build loop builds it phase-by-phase with on-system verification instead of
  the current inline `claude -p` feedback-triage prompt.
- **design (mentat)** invokes **`polish-ticket`** for an approved proposal —
  turning an approved design proposal into a self-contained, buildable ticket
  before handing it to build.

Because the skills are symlinked into `<project>/.claude/skills/` at install
(L5), an agent running with cwd at the project auto-discovers them — no extra
plumbing is needed for a headless agent to *load* the skill. What's missing is
the **invocation path**: the runner deciding "this run is a ticket, drive it
with execute-ticket" rather than the nightly feedback-triage prompt.

## Status: WIRED (Phase 11, 2026-07-21) — default OFF

`agents/build/runner.sh` now carries the gated mode:
`--mode ticket --ticket-file <path>`, a no-op unless
`[build] ticket_mode = true` (see the guard around `runner.sh:256`). An
unset/false flag is exactly the pre-Phase-11 behavior, covered by bats. What
remains manual is flipping the flag per project once its ticket flow is
trusted.

## The hook (as shipped, DEFAULT OFF)

An opt-in mode, gated so an unset flag is exactly the prior behavior:

```toml
# .agents/config.toml  — default off; absent = current behavior
[build]
ticket_mode = false          # when true, --mode ticket drives execute-ticket
```

```bash
# agents/build/runner.sh  — new branch, only reachable via --mode ticket
#   runner.sh --project DIR --mode ticket --ticket docs/tickets/<name>.md
# Guard: refuse unless [build].ticket_mode == true (else exit 2, no-op).
# Body: invoke `claude -p` pointed at the execute-ticket skill with the
# ticket path, inheriting the same wall-clock/token cap and result-file
# contract the live/incident modes already use.
```

**Tests (landed with Phase 11):** bats cases prove `--mode ticket` is a no-op
when `ticket_mode` is absent/false and dispatches to the skill path when true
— each first shown failing against the pre-change runner, per the harness
convention.
