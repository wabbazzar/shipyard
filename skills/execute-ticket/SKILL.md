---
name: execute-ticket
roles: [build, human]
disposition: adapted
kind: pipeline
description: >
  BUILD a project ticket (docs/tickets/*.md) to completion from its spec (not
  write it — that's polish-ticket). Use when the user says "execute ticket X",
  "build ticket X", "do ticket X", "implement the ticket at <path>", or hands
  off a polished ticket. You are the ORCHESTRATOR: build phase-by-phase,
  delegate heavy work to subagents, and — MANDATORY, every phase before every
  commit — VERIFY on the real system using the gate classes the ticket names
  (run the scripts, fire the units, read the event stream, curl the ports,
  render served views at the declared viewport). Which gates apply and their
  exact commands come from the project's gate file, .agents/gates.md. Never
  claim it works without exercising it, never leave the system broken between
  phases, and stop only for the user-decision class — with an owner alert via
  the project's notify command when you do. Callable headless by the build
  crew for ratified tickets, and interactively by a human operator — identical
  file, no forks.
---

# execute-ticket — build a ticket, system-verified, phase by phase

A harnessed project manages **live state**: systemd user timers firing real
agents, possibly a served app the owner reads, notifications, firewall rules,
sibling repos whose trunk branches deploy themselves. Nothing is done until the
real command shows the real output. Sessions have been burned on "the code looks
right" (a stale served bundle) and on forgotten background processes (a headless
browser hammering an API for days). The job of this skill is to make those
impossible.

You are the **orchestrator**: keep your context lean, delegate heavy/wide
work to subagents with tight briefs, and **re-verify everything yourself**
before you commit.

At the start of every invocation, put the marker below exactly once in the
first assistant commentary:

<!-- shipyard-skill:execute-ticket:v1 -->

This is an HTML comment: do not repeat it or describe it in visible user
messaging.

## Step 0 — Discover state (never assume)

- Read the project's **`.agents/gates.md`** (which gate classes apply + the
  exact commands + the project's Traps appendix), **`.agents/config.toml`**
  (trunk, test/typecheck, budgets, `can_merge`), and **`CLAUDE.md` / `README`**
  (worktree hygiene, any rebuild-after-edit rule, background-process hygiene,
  the single notification path, how privileged commands are run). The notify
  command and events dir arrive as env: `$QUARTET_NOTIFY_CMD`,
  `$QUARTET_EVENTS_DIR`. Then read the ticket + its Ledger.
- For each sibling repo the ticket names: its CLAUDE.md and gate. Respect the
  **merge-is-live hazard** — harness units run runners from a dev clone, so a
  merge to that repo's trunk is fleet-live at the next timer fire; all work
  there goes on a branch until tested.
- `git status` in EVERY repo you'll touch. Start from **CLEAN trees** (worktree
  hygiene mandates it). Dirty with unrelated work → stop and ask.
- **Green baseline before touching anything:** run the ticket's stated gate
  commands once on HEAD and record the result. If the baseline is red,
  resolve or flag first — otherwise you can't attribute failures.
- Confirm the live surfaces you'll depend on are up now (the relevant
  `systemctl --user status`, `curl` the ports, `docker ps`) so you know the
  starting line.

## Step 1 — Pre-flight the ticket (before heads-down)

For each phase, up front: **Buildable** as specced (pointers + commands
present)? A **system landmine** (touches live automation, firewall, a unit
other services depend on, a deliberately-configured value)? A **scope red
flag** (one "phase" that is really three; a "quick fix" inside a shared
runner that every project's timers execute)? Batch anything in the
user-decision class (§4) and raise it NOW — AskUserQuestion + an owner alert
via `$QUARTET_NOTIFY_CMD` — resolving it up front is far cheaper than stalling
mid-build. For everything else, apply the ticket's documented default and note
it.

For a UI-shaped phase, consult `.agents/skills/ui-design/SKILL.md` before
implementation; non-UI phases follow their existing flow unchanged. Use its
design contract while building.
Verify the real rendered surface at every ticket-declared viewport.

## Step 2 — Build each phase as a thin vertical slice

1. **Plan the slice + write it to the ticket Ledger** before working
   (anti-drift after any compaction).
2. **Delegate the slice — this is the DEFAULT, not an option.** Your context is
   the scarcest resource in the run: an orchestrator that builds inline re-reads
   its own swollen history on every turn, and the re-reading, not the work, ends
   up being what the run costs. Build each slice through a subagent with a
   TIGHT, self-contained brief **unless** it falls under one of these
   exceptions:
   1. a single-file edit in a file you have already read;
   2. a gate command whose output you must read yourself to satisfy
      verify-before-commit (§5);
   3. a change under ~30 lines;
   4. an operating constraint that forbids subagents — record it verbatim.

   **Record which, in the Ledger, every phase:** `builder: subagent (<N>
   agents)` or `builder: inline (<reason>)`. An `inline` with no recorded reason
   is a defect, not a judgment call — the whole point of the trace is that
   skipping delegation has to be a visible choice.

   Two rules follow from it:
   - **Never Read to explore.** If answering a question would take more than two
     `Read`s, or any `Read` of a file over ~500 lines, that is a subagent brief,
     not a Read. Ask for the answer, not the file.
   - **Bound what comes back.** Every brief states the return shape: ≤40 lines —
     files changed; commands run + exit codes; evidence lines (JSONL, HTTP
     codes, test counts); blockers. Longer evidence goes in the ticket Ledger,
     not your context.

   Delegating never delegates the verification: §5 stands unchanged, and you
   re-run the phase's gate yourself before every commit. Hand every subagent
   this clause verbatim:
   > Converge honestly or report the precise blocker with the actual
   > evidence — NEVER fake a green result, weaken a check, or hand-wave
   > "should work". Run the real command, read the real file, curl the real
   > port, and report exact output (exit codes, JSONL lines, HTTP codes),
   > not adjectives. If it needs a spend, an outward-facing action, or a
   > destructive change, stop and report instead.
3. **Save a safety patch** before a risky change:
   `git diff > <scratchpad>/phaseN.patch` (plus copies of new files).
4. **QA — MANDATORY, every phase, all gates the ticket names for it** (drawn
   from `.agents/gates.md`):
   - **Shell:** `bash -n` every touched script, then RUN it and read the
     output. Exit codes and printed values, not vibes.
   - **systemd:** `daemon-reload`; `list-timers` shows the expected next
     fire; `systemctl --user start <unit>` once and confirm the observable
     outcome — a `job.end` line in `$QUARTET_EVENTS_DIR/$(date +%F).jsonl`,
     journalctl, or the ticket's stated probe. Don't wait for OnCalendar.
   - **Served app at a port** (as declared in the gate file): the project's
     rebuild + restart step, curl the port for 200, then render the changed
     view at the declared viewport (mobile for a phone/PWA surface) and look
     at it. Kill the headless browser + verify with `ps` when done — every
     time.
   - **Events/notifications:** read the actual emitted JSONL line; for
     `$QUARTET_NOTIFY_CMD` either confirm one real send or stub it
     deliberately (say which in the Ledger) — don't spam the owner from a loop.
   - **Cross-repo:** the sibling repo's own gate (leak-check, its test
     suite), on its branch; merge only at the ticket's stated merge step.
   - **Live-system change:** run the ticket's verify command immediately
     after applying, and keep the written rollback command at hand.
   - **New behavior ⇒ new test/check** where the ticket says so — and it
     must be able to FAIL on the real defect.
5. **VERIFY-BEFORE-COMMIT** — re-run the phase's full gate YOURSELF. Never
   trust a subagent's "green" claim; independently re-run and READ the
   actual output (the JSONL line, the HTTP code, the test count, the
   screenshot).
6. **Commit** with explicit `git add <files>` (never `-A`), a concise
   imperative message per the project's conventions + the Co-Authored-By
   trailer, **in the repo the change lives in** — then update the Ledger with
   the commit hash, the phase's `builder:` line (§2.2), and an honest note.
   `git status` clean in every touched
   repo before moving on. The system must be healthy at every phase boundary —
   no stopped services, no half-baked units, no orphaned processes.

## Step 3 — Honest-blocker protocol

If a phase can't be made green by legitimate means: STOP iterating. Do NOT
fake green, weaken a check, loosen a gate, or leave a unit disabled to dodge
a failure. Diagnose with evidence — exactly what fails, the actual output,
why the approach can't work. If it needs a user decision → §4. If it's
genuinely bigger than the ticket assumed → report it, revert to the last
GREEN state (preserve work as a patch + note where), record the honest state
in the Ledger. A precise "here's what's left and why" beats a faked-green
tree every time. This is the single most valuable behavior in the skill.

## Step 4 — User-decision protocol (the ONLY reason to stop) + owner alert

Autonomous by default. Stop and ASK only when the decision is genuinely the
owner's: (a) **spending money**; (b) **outward-facing or public actions**
(DNS, newly exposed ports/services, publishing, messaging anyone who isn't
the owner); (c) **destructive or hard-to-reverse system changes** (deleting
data, firewall edits beyond the ticket's pre-approved ones, disabling
services other things depend on); (d) **overriding a deliberately-configured
live behavior** (a config value whose comment shows intent); (e) **a real
design fork with no sensible default** where guessing wrong burns large
work. Everything else → make the sensible call, note it, keep going.

When you DO stop:
1. **AskUserQuestion** in-conversation — concrete options with trade-offs,
   recommendation first, and what you'll assume in the meantime on other
   phases.
2. **ALSO fire an owner alert** so the owner gets a phone notification (the
   project's single notification path — nothing else):
   ```bash
   "$QUARTET_NOTIFY_CMD" "execute-ticket <slug>" "need a call: <one-line question>"
   ```
3. Continue any phases that don't depend on the answer; otherwise wait.
   Also fire a one-line notify on FINAL completion or a hard blocker.

## Step 5 — Finish

When all in-scope phases are green + committed: re-run the ticket's full
gate end-to-end once more, sweep for leftovers (`ps -eo pid,cmd | grep -iE
"chrome-headless|headless"` must be empty; `git status` clean in every
touched repo; all touched services active), update the Ledger to the TRUE
final state (honest about anything deferred + why), fire the completion
notify, and summarize: what shipped, the evidence gathered (commands +
outputs, not adjectives), decisions made, anything NOT verified.

**Graduate the ticket — deterministically, in the final phase's commit.**
Where the project files tickets by lifecycle folder, a finished ticket must not
be left sitting in `pending/`: that is exactly how a ticket dir stops being
trustworthy. Do not hand-move it — run the engine:

```bash
<shipyard>/scripts/ticket-lifecycle.sh --project <dir> --graduate <ticket-path>
```

and stage that rename **in the same commit that lands the last verified phase**.
A separate "move the ticket" commit leaves a window where the tree says the work
is unfinished, which is the failure mode this exists to prevent.

- **Only on full completion.** If any in-scope phase is deferred, blocked, or
  waiting on a user decision, the ticket **stays in `pending/`** — say so in the
  Ledger. Partial work never graduates.
- **Never freeze.** `freezer/` is the owner's call alone; an autonomous run puts
  nothing there, ever.
- **Flat projects are untouched.** Without `lifecycle_dirs` the engine exits 3
  (a deliberate no-op) and nothing moves — that is correct, not an error.
- Verify it landed: `ticket-lifecycle.sh --project <dir> --check` exits 0. This
  is a gate like any other, and CI and `install.sh --doctor` run it too.

## Adaptation Contract

- **Parameter surface** (what install configures): the gate menu and its
  commands (`<project>/.agents/gates.md`), the notify command
  (`$QUARTET_NOTIFY_CMD`), the events dir (`$QUARTET_EVENTS_DIR`), the trunk
  branch + test/typecheck (`.agents/config.toml`), the served-app dev port
  (declared in the gate file). This skill reads them; it bakes in none of them.
- **Learning surface** (where lessons accumulate): the ticket's own **Ledger**
  (honest per-phase notes that feed the next polish pass) and the project's
  `.agents/gates.md` **Traps** appendix. The honest-blocker protocol (§3) and
  the verify-before-commit rule (§2.5) exist because sessions faked green —
  each such lesson is inherited by every future caller, agent or human.

## Non-negotiables

- **Observable** — a change isn't done until the real system shows it:
  the script's output, the unit's event line, the rendered view, the port's
  response. Code inspection is never sufficient.
- **Delegate by default** — build each slice through a subagent unless it hits
  a listed exception (§2.2), and record `builder:` in the Ledger either way. An
  inline phase with no recorded reason is a defect.
- **Verify-before-commit** — re-run the gate yourself; never trust a
  subagent's green. Delegation moves the work, never the verification.
- **Never cheat the gate** — no weakened checks, no disabled units to dodge
  failures, no committing past a red gate. Green honestly or report.
- **The system stays healthy at every phase boundary** — and background
  processes you start, you stop.
- **Worktree hygiene everywhere** — explicit `git add <files>`, one clean
  commit per phase, clean `git status` in every touched repo.
- **Stop only for the user-decision class; notify when you do.**
