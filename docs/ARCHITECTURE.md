# Shipyard architecture

Shipyard is an evidence-led lifecycle for repositories. It deliberately
separates proposing work, building work, independently checking work, and
responding to operational signals.

## The main loop

```text
usage + feedback + incidents
              │
              ▼
           Design ── proposals (at most three) ──► human stamp
                                                     │
human /feature or /bugfix ──────────────────────────┤
                                                     ▼
                    write-ticket → polish-ticket → execute-ticket → review
                                                     │
                                                     ▼
                                          Release verification and critique
```

Design proposes but never edits a project. It derives evidence from the event
stream, declared usage beacons, feedback, and open medic incidents. A quiet
run proposes nothing. Denied proposals are recorded and not re-drafted.

`/bugfix` captures a reproduction and the violated observable contract before
a ticket exists. `/feature` clarifies assumptions and locks an objective,
Definition of Done, and boundaries. Both converge with approved Design work on
the same ticket workflow. A hardened ticket may proceed automatically only
when no user-decision-class item remains; projects marked `autonomous = true`
apply recorded defaults and should be private, disposable dogfood repos.

## Roles and boundaries

| Component | May do | Does not do |
|---|---|---|
| Design | collect evidence and draft proposals | edit the project or self-approve work |
| Build | triage small feedback and build approved tickets | merge around the project owner |
| Release | run gates, critique a quiet edit batch, report failures | author the change it critiques |
| Medic | inspect service signals, restart whitelisted units, revert proven bad merges | auto-build a regression repair |
| Scribe | refresh configured content and ticket lifecycle placement | escalate routine documentation failure to Medic |

Release shoulder mode is a separate opt-in edit-time path. It collects edited
paths from Claude, Codex, or Hermes, debounces them, creates one cold-context
critique, and delivers a note to the authoring session. Its hook, queue,
delivery semantics, and optional stop gate are documented in
[shoulder mode](shoulder-mode.md).

Medic routes a `regression` to Design as an incident-repair proposal. The same
human approval rule applies; the retired Medic-to-Build side door does not
create work.

## Extensions outside the five roles

The **overseer** is a fleet-level QA timer for `autonomous = true` projects.
It reads recent crew outputs and evidence, reports only unhealthy assessments,
and never edits a project. Run it manually with:

```bash
agents/overseer/runner.sh --project <dir>
```

A **specialist** is an optional, installable reviewer for one subsystem. It
keeps a project-owned decision log, protects settled invariants, and
reproduces explanations against the real system. Scaffold one with:

```bash
shipyard add-specialist <subsystem>
```

## Evidence and memory

Every run records JSONL events. Optional outcome lineage adds opaque IDs and
domain references only; it never emits prompts, diffs, filenames, or result
prose. The private dashboard reads those events locally.

For recurring failure mechanisms, a project can opt into rules memory. Its
tracked `.agents/rules-ledger.jsonl` remains the project’s reviewed source of
truth; Shipyard owns the derived index and receipts. Start advisory, validate
it, and promote it to required only after representative diffs demonstrate
useful retrieval. The authoring and rollout procedure is in
[Adapting the crew](ADAPTING.md#project-rules-memory).

## Delegation and verification

Ticket phases declare who builds them: normally a bounded subagent brief, or
an explicitly justified inline implementation. Delegation moves construction,
not accountability. The orchestrator reruns every declared gate before it
commits or claims a phase is complete.
