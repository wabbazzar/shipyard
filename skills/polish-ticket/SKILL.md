---
name: polish-ticket
description: >
  HARDEN a project ticket (docs/tickets/*.md) so a FRESH, zero-context agent
  (or execute-ticket) can build it start-to-finish, fully autonomously,
  without babysitting — and can't ship a regression. Use when the user says
  "polish ticket X", "harden this ticket", "make this ticket executable",
  "prep ticket X for autonomous build", or hands you a rough spec to turn into
  a buildable ticket. You do NOT build it — you rewrite it so building it is
  safe: self-contained context, phased into thin verifiable slices, the exact
  verification surface for each behavior (which gates apply per phase comes
  from the project's own gate file, .agents/gates.md), and the decisions
  surfaced up front. Callable headless by the design crew after a proposal is
  approved, and interactively by a human operator — identical file, no forks.
---

# polish-ticket — make a ticket safe to build unattended

Goal: hand the polished ticket to `execute-ticket` (or a cold agent) and get
correct, verified work back with no quality babysitting. A ticket is "polished"
when every way it could go wrong **on this project's live surfaces** has been
pre-empted in writing.

Tickets live in `docs/tickets/<name>.md` (header: Created / Owner / Status /
Refs). A project's tickets routinely direct work into **sibling repos** and into
**live system state** (systemd user units, containers, firewall, cron). The
polish job is to pin down, per phase, exactly which of the project's gates apply
— because unlike a single-product repo, there is no one test command that covers
everything. **Which gates exist, and their exact commands, live in the
project's gate file — you read them, you never guess them.**

## Step 0 — Discover current state (never assume; the system changes)

Read/inspect, keep only compact notes. Delegate wide sweeps to subagents.

1. **`<project>/.agents/gates.md`** — the project's gate menu: its test/build/
   lint commands, which gate classes apply (shell? systemd? a served app at a
   port? an event stream? sibling repos? live-system changes?), the notify
   command, and the **Traps** appendix (accreted incident history for this
   project). This is the primary input — the verification surface you assemble
   per phase is drawn from here.
2. **`<project>/.agents/config.toml`** — the gates and budgets the harness
   enforces: trunk branch, `test_cmd` / `typecheck`, token caps, paths,
   `can_merge` / `allow_no_ci`. The notify command and events dir arrive as env
   (`$QUARTET_NOTIFY_CMD`, `$QUARTET_EVENTS_DIR`) baked into the units.
3. **`CLAUDE.md` / `README.md`** — the project's standing mandates every phase
   must satisfy (worktree hygiene, any rebuild-after-edit rule, background-
   process hygiene, the single notification path, how privileged commands are
   run). Whatever the project declares, honor it.
4. **The most recently shipped ticket** in `docs/tickets/` — inherit its
   section structure and status-header convention; don't reinvent.
5. **Every sibling repo the ticket touches** — its own CLAUDE.md, test/check
   commands, and deploy hazards, as listed in the gate file's cross-repo table.
   **Merge-is-live hazard:** the harness units execute runners from a dev
   clone, so a merge to that repo's trunk is fleet-live at the next timer fire
   — such work must happen on a branch until tested. Name the branch strategy.
6. **The event stream** (`$QUARTET_EVENTS_DIR/*.jsonl`) and `systemctl --user
   list-timers` — the observable ground truth for any agent/timer/service work.
7. **Language toolchain**: honor the project's convention (e.g. uv-managed
   venvs where system pip is blocked). Read it from config/CLAUDE.md; don't
   assume Node vs Python.

## Harden against this checklist (A–H) — edit the ticket in place

### A. Self-containment
A zero-context agent must not have to guess. Name exact files with paths
(`repo:file:line` where it matters), exact unit/timer names, exact ports,
exact config keys. Cross-repo work names the target repo, branch strategy,
and that repo's own gate. Numbers cited from live state (event counts, config
values) get a **date and the command that produced them** — the system drifts.

### B. Orchestration protocol
State that the builder is an orchestrator: delegate heavy/wide work to
subagents with tight briefs, keep the orchestrator lean, re-verify personally.
Embed the verbatim anti-cheating brief:
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

### C. The gate (make it inescapable) — assembled per phase from the gate file
The ticket must state, for EVERY phase, which gate classes from
`.agents/gates.md` apply and the exact commands. "The code looks right" is never
proof. The standard menu the gate file draws from:
- **Shell:** `bash -n` on every touched script; then **run it for real** and
  read the output. Scripts with a `--check`/`--dry-run` flag: run that too.
- **systemd (user) changes:** `systemctl --user daemon-reload`, then
  `list-timers` shows the expected next fire, then start the service once and
  confirm the outcome where it's observable (journalctl, or a `job.end` line
  in `$QUARTET_EVENTS_DIR/$(date +%F).jsonl`).
- **Served app at a port** (as declared in the gate file): the project's
  rebuild-and-restart step, then `curl` the port for 200 — **plus** a real
  rendered check at the declared viewport (a phone/PWA surface must be checked
  at mobile viewport; desktop-width "looks fine" is not evidence). Kill any
  headless browser afterward and verify with `ps`.
- **Event stream / notifications:** if the phase emits events or notifies,
  read the actual JSONL line / confirm `$QUARTET_NOTIFY_CMD` fired (or
  explicitly stub-verify without spamming the owner — say which).
- **Cross-repo:** the sibling repo's own gate (leak-check, its tests), on a
  branch when merge-is-live applies. State the merge/rollback step.
- **Live-system changes** (firewall, cron, containers, packages): the exact
  verify command AND the exact rollback command, written in the ticket before
  the change is made.

### C2. VERIFY THE TICKET'S OWN TOOLCHAIN EXISTS
Do not hand over a ticket whose verification method you have not run at least
once **while polishing**. If it calls for bats, shellcheck, a browser, gh, an
API token — prove it works on this box now and record the exact invocation
(and any install fix) in the ticket. Where you can, replace adjectives with
**measured baseline numbers** taken during polishing (event-stream counts,
current failure rates, timings), so "fixed/improved" is a diff against a real
starting value.

### D. System discipline — traps; pin the relevant ones
Two sources. The **generic traps** every harnessed project inherits:
- Stale-bundle trap: a served app serves the *built* bundle, not a dev server
  — rebuild + restart, then curl 200, before "done".
- Runaway background browsers — every headless-browser phase ends with the
  kill + `ps` check (a forgotten one has hammered an API for days).
- Notifications only via `$QUARTET_NOTIFY_CMD` — no direct curl in scripts.
- Harness units bake env at install; editing env means re-baking the units.
- The merge-is-live hazard on the harness dev clone (§ Step 0.5).
- Legacy per-project cron launchers are forbidden (the installer removes them).
Plus the **project-specific traps appendix** in `.agents/gates.md` — read it
and pin the ones this ticket could trip.

### E. Verification surface (the heart of it)
For EACH behavior the ticket adds, write down exactly how to prove it:
which command to run, which file/port/JSONL line to read, what it must show,
and — where a test harness exists or the ticket creates one — the **specific
test case to add, which must be able to FAIL on the real defect** (a test
that can't fail is a finding, not a test). Prefer deterministic checks;
anything time/timer-dependent gets an explicit wait-or-trigger instruction
(`systemctl --user start <unit>` beats waiting for OnCalendar).

### F. Decisions
- **Locked decisions** — a table of everything already decided (so the agent
  doesn't re-litigate).
- **Open decisions with defaults** — each with a concrete default the builder
  applies, records, and proceeds with. Never block on these.
- **User-decision class — carve OUT as real questions, do NOT invent a
  default:** spending money; anything outward-facing or public (DNS, exposed
  ports, publishing); destructive/hard-to-reverse system changes (deleting
  data, firewall rules, disabling services others depend on); behavior
  changes to live automation the owner deliberately configured (e.g. a config
  value with a comment showing intent); genuine design forks where a wrong
  guess burns large work. State what the builder should assume in the
  meantime on other phases.

### G. Phasing
Thin vertical slices, each independently verifiable and a single clean
commit, ordered so **the live system is never left broken between phases**
(a half-migrated unit, a stopped service, an unbaked env). Cross-repo tickets
sequence sibling-repo phases before the hub phases that depend on them. No
big-bang phase. A final phase re-runs the whole ticket's gate end-to-end.

### H. Ledger + Definition of Done
Give the ticket a **Ledger** section (builder appends plan + commit hash per
phase, honest notes on anything deferred) and an observable DoD per phase —
stated as "this command shows X / this JSONL line appears / this port
returns 200," not "implemented." Roll-up DoD: all phases committed (worktree
clean), all gates green, live system healthy, background processes cleaned up.

## Adaptation Contract

- **Parameter surface** (what install configures, so this skill stays generic):
  the gate file path (`<project>/.agents/gates.md`) and `.agents/config.toml`;
  the notify command (`$QUARTET_NOTIFY_CMD`); the events dir
  (`$QUARTET_EVENTS_DIR`); the served-app dev port (declared in the gate file).
  None of these are baked into this skill — it reads them from the project.
- **Learning surface** (where lessons accumulate): the project's
  `.agents/gates.md` **Traps** appendix. The precedent is this skill's own
  history — its generic-traps list (§D) is accreted incident history (a stale
  bundle that made shipped changes look absent; a runaway headless browser).
  A burned session becomes a line in the gate file's Traps appendix, inherited
  by every future caller of this skill on that project. Portable lessons that
  apply to *every* project instead become an edit to §C/§D here, shipped as a
  core PR.

## Output

Rewrite `docs/tickets/<name>.md` in place (or create it) as the hardened
ticket: Goal → Context/pointers → Decisions → Phases (each: slice plan,
verification surface with exact commands, observable DoD) → Ledger (empty) →
a one-line pointer to run it with `execute-ticket`. Commit it (worktree
hygiene). Then report what you hardened and any user-decision questions that
must be answered before it's buildable (use AskUserQuestion if they block
everything).

## Notes

- Polishing is done when someone who has never seen this project could build
  the ticket correctly without asking anything except the surfaced Decisions.
- Don't build it here. If you find yourself editing scripts/units/app code
  beyond toolchain-verification (§C2), stop — that's execute-ticket's job.
- Stay discovery-first: point at "the project's gate file / config / timers"
  via the discovery steps rather than baking in today's specifics.
