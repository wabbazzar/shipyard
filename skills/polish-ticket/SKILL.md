---
name: polish-ticket
roles: [design, human]
disposition: adapted
kind: pipeline
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

Tickets live wherever the project's `[write_ticket]` config keys say they live —
`ticket_dir`, and under a lifecycle layout also `archive_dir` (complete) and
`backlog_dir` (freezer). **Read those keys; never guess a path and never assume
a flat `docs/tickets/`.** Header: Created / Owner / Status / Refs.

**Polish never moves a ticket.** You harden it *in place*, whatever folder it is
in. Graduating a finished ticket to `archive_dir` is `execute-ticket`'s job, done
deterministically by `scripts/ticket-lifecycle.sh --graduate` in the final
phase's commit; parking one in `backlog_dir` is the owner's call alone. If you
find a ticket in the wrong folder, say so in your report — do not silently
relocate it.

A project's tickets routinely direct work into **sibling repos** and into
**live system state** (systemd user units, containers, firewall, cron). The
polish job is to pin down, per phase, exactly which of the project's gates apply
— because unlike a single-product repo, there is no one test command that covers
everything. **Which gates exist, and their exact commands, live in the
project's gate file — you read them, you never guess them.**

For a UI-shaped ticket, consult the `ui-design` skill while hardening its gates.
Require its declared viewports and rendered interaction states as proof.

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
8. **Installed specialists**: discover and validate the neutral manifests before
   hardening delegation or external-repository phases. Apply the deterministic
   routing and verdict contract below; a Claude-only agent file is not an
   executable manifest.
9. **Project rules memory**: inspect `.agents/config.toml` for a `[memory]`
   table. The table's absence is authoritative opt-out; do not infer memory from
   a ledger file, a specialist decision log, or the gates file. When configured,
   leave validation, indexing, and retrieval to the installed Shipyard `memory`
   command rather than reimplementing those mechanics in this skill.

## Specialist routing during polish

Polish is the intent-aware specialist gate. Shoulder review can only inspect
real hunks later; it cannot recover an author's unrecorded plan to open a PR in
another repository. This step therefore runs before the ticket can auto-gate.

### Discovery and selection

Enumerate `.agents/specialists/*.toml` in bytewise filename order.
Validate every candidate with `agents/specialist/validate-manifest.py` from the installed Shipyard core.
An invalid manifest is a blocking configuration finding with the manifest path
and validator error; never skip it or infer the missing fields.

Normalize ticket text by converting line endings to LF and case-folding it;
case-fold non-empty semantic triggers before literal substring comparison.
A manifest matches when normalized ticket text contains a literal `ticket_triggers` entry.
A manifest also matches when a project-relative file explicitly named by the ticket matches `hunk_path_patterns`.
For file routing, collect only paths explicitly named in `Files:` entries or
inline-code spans, reject absolute/escaping paths, normalize them to POSIX
project-relative form, and apply the manifest globs as shell-style whole-path
patterns. A literal match on `external_repository_triggers` also selects the
manifest even when no local file matches. Invoke every match once, in manifest
order; do not pick only the first specialist.

When no specialist manifests are installed, perform no specialist invocation and preserve the existing specialist flow unchanged. This specialist-only no-op does not suppress an independently configured project rules-memory query.

### Invocation and verdict

Invoke each selected specialist with the manifest, generic role, project prompt, decision log, gates, and complete ticket.
The invocation is a cold, read-only review subagent; it may inspect the named
project files and use bounded read-only evidence tools, but the polish
orchestrator retains all ticket edits and decisions. A polish specialist returns review evidence only; it cannot edit product code, create a PR, or mutate cloud state.
It may propose a decision-log entry; the orchestrator records it only when its
citations support the new durable decision.

Require one structured, evidence-bearing specialist verdict: `block`, `warn`,
`note`, or `clean`; findings; decision-log/code/command citations; and, for
every live source used or attempted, URL, retrieval time, success/failure, and
the exact claim it supports. Failed current-source retrieval remains
`unverified`; model memory or copied vendor prose is not substitute evidence.
Cite the specialist slug, verdict, finding, evidence location, and live-source retrieval record in the polished ticket.
Put the citation beside the affected locked decision, open blocker, or phase
gate so `execute-ticket` does not need invisible review context.

## Planning-time project rules memory

This is the first of two independent memory gates. It shapes the executable
ticket from project-owned history; the release shoulder later repeats retrieval
against the exact real diff. A planning result or receipt never satisfies,
replaces, or seeds the exact-diff review.

### Query ordering and legacy behavior

When `.agents/config.toml` has no `[memory]` table, perform no memory query,
create no memory scope or evidence, and start no memory reviewer. Preserve the
legacy polish flow, bytes, and model/network-call count.

When `[memory]` is present, create a temporary, untracked, bounded ticket-scope
copy outside the project worktree. Include only the complete current ticket,
explicitly named project-relative files and symbols, acceptance gates, failure
signatures, and the minimum project-gate context needed to judge applicability;
never include the author transcript, hidden reasoning, unrelated files, or
customer/source-record content. Run `shipyard memory query --scope-file <bounded-ticket-copy>` from the project root before finalizing executable phases and before the Decisions auto-gate. Remove the temporary scope after the query.
The deterministic query must finish and its schema-v1 JSON must be parsed before
any memory reviewer starts. Treat a nonzero exit, malformed JSON, `valid` other
than true, missing policy/query/limit fields, candidates beyond
`max_fused_candidates`, a nonzero result without an index object, or a nonzero
candidate without its ledger citation as a memory-stage failure; do not
reconstruct or silently repair output.

A successful query with zero candidates starts no memory reviewer and is not a
degradation. Record a concise zero-match result only when memory is configured;
an empty initialized ledger therefore adds no model call. Both configured
zero-result shapes share this stable schema: version 1, command `query`,
`state = "ready"`, `valid = true`, configured mode and ledger identity, bound
query input, query features and limits, `candidate_count = 0`, `candidates = []`,
and no errors. When `active_count = 0`, require `index = null`; when
`active_count > 0` produced no match, require a complete index object. No
per-candidate citation exists in either zero-result shape. A null index for a
nonempty active ledger, an index object for an empty active ledger, or any other
missing/inconsistent field is a memory-stage failure.

### Fresh review and dispositions

For a successful nonzero result, preserve the query's stable candidate order.
The review set is exactly the first `max_prompt_records` candidates; record every
remaining candidate ID, in order, as omitted from the bounded packet by the
configured prompt limit. That omission is bounded out-of-packet coverage, not a
reviewer disposition or memory-stage failure. If any ID is omitted, report
coverage as `bounded`, never `full` or `clean`, in both `advisory` and `required`
mode; required mode does not permit stronger coverage wording.
Start one fresh, cold, read-only review subagent for the nonempty review set.
Do not reuse the ticket author, an
installed-specialist invocation, a prior memory reviewer, or any of their
transcripts. Give it only the bounded ticket scope, project gates, the review-set
records and citations, and this output contract. The reviewer may inspect
explicitly named project files read-only; it cannot edit files, launch work,
create a PR, or mutate local, cloud, or external state.

Require exactly one disposition for every review-set ID and no other IDs:
`applies`, `requires_evidence`, `falsified`, `informational`, or `superseded`.
Every disposition must cite the original ledger ID and source plus the exact
current project path, ticket contract, or gate evidence that supports it.
Duplicate, missing, extra, omitted-candidate, unknown, or uncited dispositions
are malformed reviewer output; similarity or model prose alone is never
evidence.

Materialize every `applies` rule as a cited ticket requirement and deterministic
test. In `required` mode, materialize every `requires_evidence` rule as a cited
blocking preflight/phase gate and keep it incomplete until the named evidence
exists. In `advisory` mode, record it instead as an explicitly nonblocking
degraded-evidence item beside the affected phase; it must not become an open
Decision or stop gate and must not claim the evidence exists. Preserve
`falsified`, `informational`, and `superseded` dispositions with their citations
as nonblocking planning evidence. Record the query identity, ordered query
candidate IDs, review-set IDs, ordered out-of-packet IDs, dispositions, and
coverage/degradation state beside the affected Decisions or phases; never copy
vectors or present generated reviewer prose as project fact.

### Policy-mode result

In `required` mode, any query failure, malformed retrieval output, unavailable
fresh reviewer, malformed disposition set, or missing required evidence becomes
an explicit memory blocker before the existing specialist and Decisions
preconditions. It prevents `execute-ticket`, including when `autonomous = true`.
In `advisory` mode, record the same failure or missing evidence loudly beside
every affected phase, continue through the existing gate, and state that memory
coverage is degraded; never emit or imply a clean/full-memory verdict.

This planning query does not write an exact-diff receipt. The later release
shoulder must independently run `shipyard memory query --diff-file <exact-full-diff>` and start another fresh, transcript-free reviewer for every eligible changed diff; neither query may reuse the other's review result.

### External Infrastructure/Platform escalation gate

A configured external Infrastructure or Platform PR phase stays non-executable until all five preflight rows are evidenced.
The five rows are current primary documentation, live read-only state, existing internal patterns, local IAM/resource behavior, and narrower local fixes.
The ticket must name the command/file/source used for each row and the observed
result, not merely say it was checked. A missing row, an unsupported claim, an
`unverified` source needed for the decision, or a `block` verdict becomes an
explicit open blocker in Decisions and prevents the auto-gate from invoking
`execute-ticket`. `warn`, `note`, and `clean` do not waive a missing row.
Do not broaden this gate to repositories absent from
`external_repository_triggers`, and do not let it prevent unrelated local
investigation from being specified while evidence is gathered.

## Harden against this checklist (A–H) — edit the ticket in place

### A. Self-containment
A zero-context agent must not have to guess. Name exact files with paths
(`repo:file:line` where it matters), exact unit/timer names, exact ports,
exact config keys. Cross-repo work names the target repo, branch strategy,
and that repo's own gate. Numbers cited from live state (event counts, config
values) get a **date and the command that produced them** — the system drifts.

### B. Orchestration protocol — harden every Delegation line into a brief
State that the builder is an orchestrator: delegate by default, keep the
orchestrator lean, re-verify personally. Embed the verbatim anti-cheating brief:
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

Then do the hardening this step exists for. `write-ticket` leaves each phase a
`Delegation:` line naming **intent**; you turn each one into something a cold
subagent can execute:

- **`Delegation: subagent`** → write the actual brief, self-contained: the
  inputs it may assume, the exact question or change, the files it owns, and its
  **return shape — ≤40 lines: files changed; commands run + exit codes; evidence
  lines (JSONL, HTTP codes, test counts); blockers.** Evidence longer than that
  belongs in the ticket Ledger, not the orchestrator's context. Append the
  anti-cheating clause above to every brief.
- **`Delegation: inline`** → confirm the reason is one of the real exceptions
  (a single-file edit in an already-read file; a gate command the orchestrator
  must read itself; a change under ~30 lines; an operating constraint that
  forbids subagents) and keep it. An `inline` with a vague reason gets rewritten
  as a brief.
- **A phase with no `Delegation:` line at all** → add one. Silence defaults to
  inline, and a run built inline spends most of its cost re-reading its own
  history rather than doing work.

**Name the specialist when the project has one.** If
`<project>/.agents/build.md` carries a "delegate to specialists" table (the
installer writes it from checked-in `.claude/agents/*.md`), point the brief at
the right specialist by name. Many projects have none — when it is **absent**,
write a generic brief and move on; never invent a specialist.

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
- A test that greps prose (a SKILL.md clause, a role prompt) must assert a
  phrase that fits **within one source line** — Markdown is hard-wrapped, so a
  regex spanning a line break can never match. And a *guard* case (one asserting
  existing behavior survived an edit) must be shown **passing against the
  pre-change file**: a guard that fails pre-change is asserting nothing.
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
phase, the phase's `builder: subagent (<N> agents)` / `builder: inline
(<reason>)` line, and honest notes on anything deferred) and an observable DoD
per phase —
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
  tracked `.agents/rules-ledger.jsonl` for structured historical rules and the
  `.agents/gates.md` **Traps** appendix for concise operational gotchas. Do not
  scrape, migrate, or synthesize either surface during polish. Portable lessons
  that apply to *every* project instead become an edit to §C/§D here, shipped as
  a core PR.

## Output — hardened ticket, then the auto-gate

After any configured planning-memory review has been materialized, rewrite
`docs/tickets/<name>.md` in place (or create it) as the hardened
ticket: Goal → Context/pointers → Decisions → Phases (each: slice plan,
verification surface with exact commands, observable DoD) → Ledger (empty) →
a one-line pointer to run it with `execute-ticket`. Commit it (worktree
hygiene).

Then **auto-gate** on the ticket's Decisions. The pipeline does NOT stop for a
separate human stamp — the command invocation (or the already-approved dispatch
proposal) IS the authorization. Apply the preconditions below in order, then
decide user-decision-class items from the Decisions section:

- **Required-memory precondition:** before specialist or Decisions handling, a
  `required` planning-memory query has completed and every nonempty review set
  has one valid, cited disposition per review-set ID, with candidates beyond
  `max_prompt_records` recorded as ordered bounded-coverage IDs. Any required
  memory blocker stops before `execute-ticket`. The autonomous-project exception
  does not override this precondition.

- **Advisory-memory handling:** attempt configured advisory query/review before
  specialist handling, but completion and dispositions are not an auto-gate
  precondition. A stage or reviewer failure records explicit degradation beside
  affected phases and proceeds without claiming clean/full-memory coverage.

- **Specialist precondition:** before applying the decision rules below, every
  selected specialist has an evidence-bearing specialist verdict cited in the
  ticket. Any specialist `block` or incomplete configured external escalation
  remains an open blocker, so the ticket does not proceed to `execute-ticket`.

- **Any open decision → STOP.** If even one **user-decision-class** item (§F —
  spending money; anything outward-facing/public; destructive or hard-to-reverse
  changes; changing the behavior of live automation the owner deliberately
  configured; a genuine design fork where a wrong guess burns large work) is
  unresolved, surface exactly those with `AskUserQuestion` and wait. Resume the
  pipeline automatically once they're answered. (An "open decision with a
  default" is NOT a blocker — the builder applies the recorded default and
  proceeds; only the user-decision class blocks.)
  - **Exception — autonomous projects.** If the project's `.agents/config.toml`
    declares `autonomous = true` (a private, disposable dogfood repo with no
    human in the loop, e.g. caladan), Decisions handling never stops for a
    user-decision-class item. Apply each open decision's recorded default (or the
    safest available option), record what you auto-decided in the ticket Ledger,
    and proceed to build only after the memory and specialist preconditions are
    satisfied. This flag is set only on throwaway private repos; never assume it
    — read it.
- **No open decision → PROCEED automatically to `execute-ticket`.** Build every
  phase, run all gates, and commit/push/deploy per the project's flow. The
  project's capability config still bounds what "deploy" means — `[medic]
  can_merge`, PR-vs-merge, `allow_no_ci`, `forbidden_paths` are unchanged and
  the auto-gate never overrides them (with `can_merge=false` the build pushes a
  branch + opens a PR rather than self-merging).

Report what you hardened, then either the build result or the exact open
decision(s) that blocked.

## Notes

- Polishing is done when someone who has never seen this project could build
  the ticket correctly without asking anything except the surfaced Decisions.
- Don't edit app code in the polish step itself (beyond toolchain-verification,
  §C2) — the actual build is `execute-ticket`'s job, which the auto-gate invokes
  for you when there is no open decision.
- Stay discovery-first: point at "the project's gate file / config / timers"
  via the discovery steps rather than baking in today's specifics.
