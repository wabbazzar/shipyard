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

## Status: documented, NOT yet wired (deferred to Phase 11)

`agents/build/runner.sh` is a 540-line orchestrator of merge / CI / `gh` /
revert logic, executed by **every project's timers from the dev clone** — the
merge-is-live hazard. Adding a ticket-execution branch to it is a real behavior
change to the live fleet's core path and deserves its own tested phase (bats
fixtures for the new mode + the default-off flag, each first shown failing).
That is precisely Phase 11's scope (mentat: proposals → polish-ticket →
helldiver). **Prefer safety: no change to the live runner in the skills-parity
phase.**

## The intended hook (for Phase 11 to implement, DEFAULT OFF)

A new opt-in mode, gated so an unset flag is exactly today's behavior:

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

**Test before wiring (Phase 11):** a bats case proving `--mode ticket` exits 2
(no-op) when `ticket_mode` is absent/false, and a second proving it dispatches
to the skill path when true — each first shown failing against the pre-change
runner, per the harness convention. Until those land, the live fleet's build
behavior is unchanged.
