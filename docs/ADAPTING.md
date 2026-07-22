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
- **Learning surface** — the one file where lessons for that skill accumulate:
  e.g. the project's `.agents/gates.md` **Traps** appendix (for polish-ticket /
  execute-ticket), or the triage output routed by `coverage-audit`.

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

## The routing rule (stated once)

| The lesson is… | Route it to… |
|---|---|
| a one-off correction for this ticket | the ticket's decision tables |
| project taste (LOC, deps, naming) | `.agents/<role>.md` `## Conventions` |
| a project gate or budget | `.agents/config.toml` / `.agents/gates.md` |
| portable doctrine | a core PR (leak-checked, fleet-live on merge) |
| a question every future install should ask | the installer interview |
