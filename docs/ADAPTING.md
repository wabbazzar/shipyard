# Adapting the crew — five feedback channels

Adaptation here is **not** fine-tuning. It is versioned edits to the files
agents and humans share — every lesson routed to the layer where it belongs,
inherited by every future caller. A burned session becomes a reviewable,
revertable line in a skill, rubric, ticket, or config; no caller repeats it.

## The Adaptation Contract

Every adapted skill declares two surfaces, so generalizing never means gutting:

- **Parameter surface** — what the installer configures, so the skill stays
  generic: gate-file path, notify command, events dir, ports, trunk branch.
  These are read from the project, never baked into the skill.
- **Learning surface** — the project-owned file where lessons for that behavior
  accumulate: e.g. `.agents/gates.md` **Traps** for build procedure, or the
  structured `.agents/rules-ledger.jsonl` for a recurring failure mechanism
  that should be associated with future scopes and diffs.

Each skill's `## Adaptation Contract` section names both. When you correct a
behavior, the correction lands on that skill's learning surface.

## The five channels

### 1. Operator corrections → skill files
When the operator corrects a behavior, the correction lands as an edit to the
skill, rubric, or ticket — reviewable, revertable, inherited. This system's own
history is the precedent: polish-ticket's "traps" material is accreted incident
history (a stale served bundle that made shipped changes look absent; a runaway
headless browser that hammered an API for days), and execute-ticket's
honest-blocker protocol exists because sessions faked green. **Burned session →
line in the skill file (or the project's gates.md Traps appendix) → no caller
repeats it.**

### 2. coverage-audit triage → rubric + proposals (the router)
Session transcripts are mined for bugs the operator reported that tests missed.
Each miss is triaged into exactly one destination — **this taxonomy IS the
adaptation router**:
- **project-specific** → `<project>/.agents/<role>.md` (a rubric line or check
  meaningful only here)
- **generic** → a core `agents/<role>/role.md` PR (leak-checked, fleet-live on
  merge) with the config flag that gates it
- **install-time** → a new question in the installer interview

The same audit feeds two consumers: the design crew proposes work from it, the
release critic tightens its rubric from it.

### 3. User feedback → build
Asynchronous feedback (chat notes, `fyi-requests.jsonl`) is triaged nightly by
the build crew into PRs. Substantial asks become design proposals instead of
drive-by patches — recurring pain becomes design signal, not a one-off fix.

A **synchronous** human ask enters the same loop through the front-door skills:
`bugfix` (reproduce-and-root-cause first) and `feature` (clarify and set a
Definition of Done first) do the intent-specific intake and hand `write-ticket`
a scope. `write-ticket → polish-ticket → execute-ticket` is the one road, and a
stamped mentat proposal drafts into a ticket through the identical
`write-ticket` file the human front doors use — the machine path and the human
path converge, no agent-only fork. `polish-ticket`'s **auto-gate** then
decides: no open decision → it drives straight through `execute-ticket`; an
open user-decision-class item (spend, outward-facing, destructive,
live-automation behavior, design fork) → stop and surface it via
`AskUserQuestion`. An `autonomous = true` project skips even that stop.

### 4. Agent → agent
Agents correct each other through the same reviewable surfaces humans use:
- the **release critic's** findings drop into the working agent's live session
  as notes (never hard stops);
- an **on-call incident** becomes design signal at the top of the loop (a
  repeated incident becomes a proposal, not a repeated patch);
- **execute-ticket's** Ledger notes feed the next **polish-ticket** pass.

### 5. Pruning
Rubric and convention lines that only ever produce notes for two weeks are
removed. **Adaptation includes forgetting** — a critic that flags everything
teaches nothing.

## The specialist archetype (an installable sixth role)

The five roles are lifecycle janitors — none is a standing **subsystem expert**.
When a project has a subsystem whose settled decisions keep getting
re-litigated by fresh-context agents, install the **specialist** archetype
(`agents/specialist/role.md` + `decision-log.template.md`): a knowledge-bearing
*reviewer* that reads a living decision log before it answers, guards the
subsystem's objectives/invariants/rejected-approaches against erosion,
reproduces "why does X happen" against the real system rather than narrating a
plausible story, and maintains that log. It **reviews; it does not redesign** —
building stays behind the same human stamp as every other role.

Reach for it when a decision's rationale lives only in someone's head or a
stale PR thread, and its loss would cost real rework. It is scaffolded into a
project by `/shipyard add-specialist <subsystem>`, which instantiates the
templates for the named subsystem and wires the decision log into the project's
`write_ticket` context, its gates note, and a **hunk-keyed** release-critic
block (never a changed-file-membership one — see the critic input contract).

## Project rules memory

Project rules memory handles a different failure mode from a specialist or a
long prose appendix: a new agent edits a related hunk but does not associate it
with an older incident. The ownership boundary is deliberate:

- **Shipyard owns mechanics:** the strict record schema and parser, path/size
  safety, deterministic local hybrid retrieval, cache identity/publication,
  planning and exact-diff reviewer contracts, receipt binding, status, and
  Doctor diagnostics. These remain generic and versioned in Shipyard.
- **Each project owns rules:** `.agents/rules-ledger.jsonl` is tracked beside
  `.agents/config.toml`, reviewed like code, and contains only project-safe
  summaries, mechanisms, rules, required evidence, associations, remediation,
  and source references. Customer records, transcripts, secrets, and hidden
  reasoning never belong there.

### Authoring and migration

Run `shipyard memory init` once; it adds advisory `[memory]` configuration and
an empty ledger idempotently. Convert an existing incident log one event at a
time: use a stable ID, describe the mechanism rather than the one-off symptom,
associate likely paths/symbols/subsystems/state transitions, state the concrete
guard and deterministic evidence future changes owe, and cite a safe ticket,
commit, issue, or project-relative path. Preserve old entries as `superseded`
with explicit `supersedes` links instead of rewriting history. Run `shipyard
memory validate` before review. Free-form logs may remain provenance; they are
not queried until deliberately normalized into this ledger.

### Rollout and operation

Start in `advisory`. Replay representative bad, guarded, and unrelated diffs:
the bad diff should produce a cited requirement, the guarded diff should
falsify the same candidates with current evidence, and unrelated prose should
spawn no memory reviewer. Move to `required` only after those checks are stable;
required mode fails closed on malformed/missing ledgers, unavailable or stale
retrieval, malformed reviewer output, and mismatched receipts. Advisory reports
the same degradation without creating a release stop.

Receipts never accept an unresolved model identity. With the default Claude
reviewer, Shipyard pins the memory-only invocation to `sonnet` and records
provider `claude`. If the release shoulder uses Codex or Hermes, configure an
explicit release/harness model before enabling memory; otherwise advisory mode
reports `reviewer_identity` and required mode keeps the queue closed.

The index under the user cache directory is disposable derived state. It is
bound to project identity, exact ledger bytes/canonical digest, schema,
normalizer, FTS backend, embedding backend, and Shipyard index version. To
recover from a stale/corrupt status, move only the status-named project cache
directory aside, then run one bounded `shipyard memory query`; never edit the
SQLite file or treat it as evidence. An empty ledger needs no index.

`shipyard status` is read-only and reports policy, validated record counts and
digest, index freshness, embedding availability, and the newest exact-diff
receipt. `complete` means its bound inputs still match and delivery was
deposited; `degraded` records an explicit review/runtime failure; `stale` means
a bound ledger/config/gate/index identity changed or delivery was incomplete;
`invalid` means the artifact is unsafe or malformed; `absent` means no exact
diff has yet produced one. Diff freshness is reported as unverified when the
current generation cannot be reconstructed from receipt metadata alone. Status
and Doctor expose codes/actions, never ledger or reviewer prose.

The coverage boundary stays honest: retrieval proposes bounded historical
candidates; it does not prove applicability, discover incidents never authored
in the ledger, or replace a deterministic regression test. One fresh reviewer
must decide every selected rule against the exact current scope/diff and cite
both rule and path. Scores alone never block; a falsified candidate does not
block; omitted candidates and degraded stages remain explicit in receipts.

## The routing rule (stated once)

| The lesson is… | Route it to… |
|---|---|
| a one-off correction for this ticket | the ticket's decision tables |
| project taste (LOC, deps, naming) | `.agents/<role>.md` `## Conventions` |
| a project gate or budget | `.agents/config.toml` / `.agents/gates.md` |
| a recurring project failure mechanism associated with future diffs | `.agents/rules-ledger.jsonl` via `shipyard memory init|validate` |
| portable doctrine | a core PR (leak-checked, fleet-live on merge) |
| a question every future install should ask | the installer interview |
| how a phase should be *built* (who does the work) | the ticket's `Delegation:` line → the Ledger's `builder:` line |

`/shipyard learn "<lesson>"` applies this rule mechanically: `--to project`
appends a note to `.agents/<role>.md`, `--to generic` drafts a `docs/tickets/`
core-change stub (reviewed before it touches a core role file), and `--to
install` drafts an installer-question proposal — with a keyword heuristic when
`--to` is omitted, and an honest "ambiguous, re-run with --to" (exit 2) rather
than a mis-route.
