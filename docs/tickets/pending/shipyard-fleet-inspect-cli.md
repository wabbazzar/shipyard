# Shipyard Fleet Inspect CLI: health, operator focus, and evidence-backed next-PR priorities

- **Created:** 2026-07-29
- **Owner:** wabbazzar
- **Status:** Draft — ready for `polish-ticket`
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 15 (4 phases, each within the 5-point cap)
- **Refs:** `skills/shipyard/{SKILL.md,shipyard.sh}`, `install.sh --doctor`,
  `agents/design/collectors.sh`, `scripts/delegation-report.py`,
  `docs/deck-editorial.json`, `.agents/gates.md`

## Goal

Add a whole-fleet, read-only `shipyard inspect` command to the existing
`/shipyard` operator console. From any project carrying the shared Shipyard
skill, a human, Claude, Codex, or Hermes must be able to ask one deterministic
command:

```bash
bash .claude/skills/shipyard/shipyard.sh inspect
bash .claude/skills/shipyard/shipyard.sh inspect --json
```

The command discovers the Shipyard installations on the current system,
reports fleet health and places requiring operator attention, makes Shipyard's
effectiveness visible, and ranks evidence-backed places where the next
**Shipyard-core** PR could improve the system. The default is a concise operator
report; `--json` returns the stable source document from which that report is
rendered.

It only observes. It never approves a proposal, starts or restarts a unit,
writes a ticket, changes configuration, refreshes an assessment, or calls a
model.

## Problem / Background

### The current console stops at one project

`/shipyard` is already the cross-harness operator entry point. The installer
links the same `skills/shipyard/` directory into `.agents/skills/` for Codex
and `.claude/skills/` for Claude/Hermes, so there is one implementation rather
than three harness forks (`install.sh:815-849`). Its deterministic core is
`skills/shipyard/shipyard.sh` (`skills/shipyard/SKILL.md:27-31`).

The existing default `status` command is deliberately narrower:

- it derives one project from `PWD`/`--project`
  (`skills/shipyard/shipyard.sh:22-49`);
- it declares that project installed when matching timer files exist
  (`skills/shipyard/shipyard.sh:72-89`);
- it lists project role blocks and optionally prints a doctor audit
  (`skills/shipyard/shipyard.sh:91-103`);
- its doctor failure is text only because `|| true` masks the exit status
  (`skills/shipyard/shipyard.sh:97-102`).

That is useful local wiring information, but it cannot answer:

1. Is the installed fleet healthy?
2. Where does the operator need to look now?
3. Is Shipyard doing useful work, or merely running?
4. Which evidence suggests the highest-leverage next PR to improve Shipyard
   itself?

### The presentation already defines what deserves attention

The public deck provides the product vocabulary this CLI should operationalize:

- human-gated proposals and deny suppression
  (`docs/deck-editorial.json:43-96`);
- incidents, critic block/warn/note findings, and undelivered critique findings
  (`docs/deck-editorial.json:173-231`, `:716-726`);
- install/timer/config drift and effective safety gates
  (`docs/deck-editorial.json:228-231`, `:776-779`);
- failure rate, budget consumption/deferral, and proposal-cap pressure
  (`docs/deck-editorial.json:300`, `:884-905`);
- four effectiveness floors: real bugs caught and fixed, usage assessed on at
  least three projects, a feature shipped end-to-end, and a consequential
  human decision surfaced (`docs/index.html:439-450`);
- critique actionability of at least one-third, with noisy checks pruned
  (`docs/deck-editorial.json:320`);
- the adaptation router: missed-user-bug classes become project-specific
  config, a generic Shipyard-core PR, or an installer question
  (`docs/deck-editorial.json:103`, `:411-423`).

Today those facts are spread across shell commands, JSONL, result files, and the
ICE dispatch. An operator or agent has to know every location and reconstruct
the story manually.

### The read-only ingredients mostly exist

The first version should compose existing evidence rather than introduce a new
telemetry system:

| Evidence | Existing source | Relevant contract |
|---|---|---|
| Installed fleet | installer-owned user service manifests | unit identity and runner realpath checks in `install.sh:149-160`, `:193-216`, generated `WorkingDirectory`/`ExecStart` in `:714-724` |
| Install integrity | `install.sh --doctor --project DIR` | one `DOCTOR <class>: <detail>` per finding, exit 0 clean / 1 drift (`install.sh:166-172`, `:373-378`) |
| Jobs, incidents, critiques | append-only event JSONL | canonical events documented in `README.md:420-429`; existing aggregation in `agents/design/collectors.sh:85-121` |
| Feedback and usage | per-project FYI and usage JSONL | `agents/design/collectors.sh:123-158` |
| Open proposals | `tmp/*-mentat-result.json` minus `data/decisions.jsonl` | result/decision lifecycle in `agents/design/runner.sh:17-33`, `:228-241` |
| Existing fleet assessment | `tmp/overseer-result.json` | persisted `{healthy,status,summary,findings,ts}` in `agents/overseer/runner.sh:26-31`, `:170-190` |
| Harness/pipeline use | `scripts/delegation-report.py --source all --json` | read-only windowed report in `scripts/delegation-report.py:620-695` |

The CLI must also expose the gaps instead of laundering them into reassuring
zeros:

- collectors currently combine `job.end status=fail|abort` even though some
  aborts are benign (`agents/design/collectors.sh:93-96`,
  `agents/build/runner.sh:128`);
- only Caddy explicitly distinguishes unavailable from empty; absent FYI or
  usage files become zero counts (`agents/design/collectors.sh:143-157`,
  `:199-207`);
- event logging is fire-and-forget, has no schema/run ID, and cannot prove that
  an absent event means health (`agents/lib/log_event.sh:21`, `:73`);
- proposal/build results do not yet carry enough common linkage to prove that a
  proposed bug was fixed or a feature shipped
  (`agents/design/runner.sh:17-33`, `agents/build/runner.sh:16`);
- critique events count findings but do not record the operator's actionable
  judgment or resolution, so the deck's one-third actionability target is not
  currently measurable (`agents/release/critic-watch.sh:395-403`);
- delegation reporting supports Claude and Codex cohorts but not Hermes
  (`scripts/delegation-report.py:623-627`).

Those gaps are themselves legitimate `instrumentation_gap` candidates for the
next Shipyard-core PR.

## Confirmed Product Scope

The feature intake verified the technical/process assumptions and the owner
confirmed all three product boundaries on 2026-07-29:

1. **Whole fleet:** inspect every Shipyard installation on the system, not only
   the current project.
2. **Strictly read-only:** report and recommend; never take an action.
3. **Two renderings, one document:** concise human output by default and stable
   JSON for agents/automation.

## Objective

On a system with one or more installer-owned Shipyard crews, `shipyard inspect`
must produce within one local invocation a truthful, deterministic assessment
of the whole installed fleet over a declared time window. The assessment must:

- distinguish observed facts, deterministic derivations, and persisted
  model/human assessments;
- identify unhealthy or degraded projects and work awaiting the operator;
- show which presentation-defined effectiveness outcomes are measured,
  partially measured, or unmeasured;
- emit a deterministic, evidence-linked ordering of candidate areas for a
  Shipyard-core improvement PR;
- render the same versioned document as human text or JSON;
- make unavailable/stale sources explicit; and
- leave project files, systemd state, event streams, ledgers, sessions, and the
  network byte-for-byte/state-for-state unchanged.

## Decisions

### Locked

| # | Decision | Rationale |
|---|---|---|
| L1 | Extend the existing `/shipyard` surface with `inspect`; do not install a second global binary. | `shipyard.sh` is already the shared deterministic core across all three harness discovery roots. |
| L2 | `inspect` is fleet-wide by definition. `status` remains the existing per-project/default command. | Whole-fleet scope is owner-confirmed; preserving `status` avoids a breaking change. |
| L3 | Discover installations only from installer-owned user `.service` manifests whose canonical runner resolves into this `QUARTET_DIR`; dedupe by canonical project path. | Avoids treating arbitrary `CODE_ROOT` checkouts, stale unit names, or another Shipyard checkout as this fleet. |
| L4 | A skills-only checkout with no installer-owned service is not a fleet member; report this discovery limitation in metadata/docs. | There is no authoritative system-wide registry for skills-only installs. |
| L5 | Human output is a rendering of the same in-memory document returned by `--json`; it is not assembled through a separate data path. | Prevents agents and humans receiving contradictory assessments. |
| L6 | JSON carries `schema_version: 1`; new fields may be additive, but removal/renaming is a versioned compatibility change. | Gives Claude, Codex, Hermes, and shell callers a stable contract. |
| L7 | Default window is 7 UTC days; `--days N` accepts a positive integer. Every section records the exact window or source timestamp it used. | Matches the design collector's existing window while making freshness explicit. |
| L8 | Exit 0 means a report was produced, including a report with unhealthy findings; exit 2 means malformed invocation/config; exit 3 means no eligible Shipyard installation. | Health belongs in report data, not process failure. It preserves the console's load-bearing 0/2/3 contract. |
| L9 | No config key is added. `inspect` is an explicit opt-in subcommand and leaves the no-argument/`status` path byte-for-byte behaviorally unchanged. | The formal additivity gate targets runner/installer behavior. A preservation test resolves the broader house-rule wording without inventing a disabled-by-default inspection knob. |
| L10 | Implement structured aggregation in a stdlib-only helper inside `skills/shipyard/`, invoked by `shipyard.sh`; no package or service is introduced. | Complex parsing/ranking needs structured code, while the whole skill directory is already installed by symlink. |
| L11 | Fixed priority categories, in order: `confirmed_failure`, `human_gate`, `recurring_failure`, `evidenced_opportunity`, `instrumentation_gap`, `hygiene`. | Mirrors the design loop's failure/repeated-ask/hot-path/blind-spot vocabulary without an opaque composite score. |
| L12 | Every priority declares `claim_kind: fact|derived|assessment`, `rule_id`, evidence operands, source records, `confidence_basis`, and `limitations`. | A heuristic must explain itself and must never be presented as ground truth. |
| L13 | Within one category, order by direct evidence count descending, newest evidence timestamp descending, then stable project/signal ID. | Deterministic, inspectable ordering; no model or hidden weights. |
| L14 | Only deterministic cross-project/core evidence enters “next Shipyard PR.” Project-local app problems remain under operator attention and are not mislabeled as core defects. | The requested focus is improving Shipyard, not silently routing every application bug into this repo. |
| L15 | Existing Overseer output is read if present but never refreshed. It is labelled an `assessment`, not a fact. | Invoking Overseer would write a result and spend model tokens, violating read-only scope. |
| L16 | North stars may be displayed as context or deterministic tie-break metadata; they never override evidence. | The design contract says the north star ranks but never gates. |

### Open decisions

**None.** The owner confirmed every build-shaping product choice. Engineering
defaults are locked above and can be reviewed in the ticket/PR.

### User-decision class

**None.** The command is local, read-only, non-destructive, non-networked, and
adds no service, spend, outward-facing action, or unresolved design fork.

## Output Contract

The exact field-level schema is hardened in Phase 1, but the following
top-level meanings are load-bearing:

```json
{
  "schema_version": 1,
  "meta": {},
  "coverage": [],
  "fleet": [],
  "attention": [],
  "effectiveness": {},
  "priorities": [],
  "summary": {}
}
```

### `meta`

Must include generation time, exact UTC window start/end, requested day count,
the resolved Shipyard root, fleet/project inventory, policy/rule version, and
the discovery limitation for skills-only installs.

### `coverage`

One record per attempted evidence source, with at least:

```json
{
  "source": "events",
  "project": "example",
  "available": true,
  "reason": null,
  "newest_ts": "2026-07-29T10:00:00Z",
  "records_read": 42
}
```

Missing, unreadable, malformed, unsupported, and stale are distinct reasons.
An unavailable source never silently produces a healthy zero.

### `fleet`

One project record per canonical installed project path:

- manifest-derived installed roles and unit names;
- read-only unit/timer state, last/next fire when available;
- doctor clean/drift plus structured finding classes;
- exact `job.end` statuses/reasons (do not merge `abort` into `fail`);
- latest run and duration facts;
- deduped incidents by `incident_id` with latest consolidated facts;
- critic counts plus separate spawn/delivery/budget-deferral failures;
- existing Overseer assessment, explicitly labelled and timestamped;
- source coverage/limitations local to that project.

### `attention`

Operator work, not automatic action:

- undecided/open proposals, after applying the per-project decisions ledger;
- explicit owner decisions or gates represented in available local evidence;
- direct failures/drift that need investigation;
- stale or missing evidence that prevents a health claim.

Each item carries project, age, evidence, source timestamp, and a statement of
what remains for the human. Proposal severity is advisory metadata, never
silently promoted to a fact.

### `effectiveness`

Report every presentation-defined outcome with:

```json
{
  "state": "measured",
  "value": 1,
  "target": 1,
  "evidence": [],
  "reason": null
}
```

`state` is `measured|partial|unmeasured`. Required outcomes:

- bugs caught and fixed;
- projects with usage assessed;
- features shipped end-to-end through the Shipyard loop;
- consequential human decisions surfaced;
- critique actionability against the one-third target;
- observable delegation/harness-use indicators when the existing reporter is
  available.

If current IDs cannot connect proposal → ticket → build → decision, the value
is `unmeasured` with the missing linkage named. The CLI must not award itself
credit by counting disconnected events.

### `priorities`

Priorities are recommendations about where to investigate or focus the next
Shipyard-core PR, never commands and never proof that a change is correct.

Deterministic rule examples to pin during hardening:

- `confirmed_failure`: doctor drift; `job.end status=fail|partial`; failed
  restart; critic spawn/delivery failure.
- `human_gate`: an undecided Shipyard proposal or explicit core owner decision.
- `recurring_failure`: at least two exact matching direct records in the window;
  free-text semantic clustering is forbidden in v1.
- `evidenced_opportunity`: exact usage/action/path counts or an already-open
  Shipyard proposal with real signal IDs.
- `instrumentation_gap`: an unavailable source or missing linkage that blocks a
  presentation-defined effectiveness claim.
- `hygiene`: stale evidence, duplicate unit manifestations, or low-severity
  deterministic drift not covered above.

A candidate is scoped `shipyard-core` only when evidence directly names the
Shipyard project/core component, or the same stable rule/reason occurs across
multiple installed projects. Otherwise it remains project-local attention.

## Implementation Plan

### Phase 1 — Fleet discovery and versioned report skeleton (3 pts)

**Goal:** introduce the explicit command and a deterministic, hermetic fleet
inventory without changing existing `status`.

**Delegation:** subagent — implement the new inspect helper, shell dispatch, and
focused red-first fixture tests; return files changed, RED/GREEN case names and
counts, exact exit codes, sample JSON keys, and blockers.

**Work:**

- Add `inspect`, `--json`, and `--days N` to the argument/usage/dispatcher
  surface in `skills/shipyard/shipyard.sh` around its current parser
  (`:22-39`), usage (`:58-70`), and dispatcher (`:329-337`).
- Add a stdlib-only aggregation helper under `skills/shipyard/`; the helper
  owns the versioned JSON document and human rendering.
- Discover candidate user service manifests below the redirected/real
  `$HOME/.config/systemd/user`, accept only canonical role runners owned by
  the resolved `QUARTET_DIR`, extract `WorkingDirectory`/`--project`, and
  deduplicate canonical paths.
- Add `tests/shipyard-inspect.bats` using redirected `HOME`, synthetic service
  manifests, fixture projects, and stubbed commands.
- Pin exclusion of unrelated services, stale/other Shipyard roots, duplicate
  themed units, and arbitrary uninstalled `CODE_ROOT` projects.
- Pin exit 3 for no eligible units, exit 2 for malformed days/flags, exit 0 for
  a report even when its fixture contains unhealthy data.
- Preserve existing `status` output/default and existing
  `tests/shipyard-status.bats` behavior.

**Gate classes:** Shell scripts · bats · Public-repo hygiene · Delegation
contract.

**Observable DoD:** one fixture with multiple roles/projects yields exactly one
canonical record per installed project in both renderings; JSON schema version
and inventory fields are exact; all exclusion and exit-semantics cases pass;
the pre-change `inspect` case was recorded RED.

### Phase 2 — Health, coverage, and operator-attention adapters (5 pts)

**Goal:** turn installed projects into a truthful assessment of what is known,
unhealthy, stale, or awaiting the operator.

**Delegation:** subagent — build read-only source adapters and hermetic fixtures
for systemd/doctor/events/proposals/assessments; return source-by-source
coverage, exact fixture totals, mutation-proof evidence, test exits, and
blockers.

**Work:**

- Read machine-readable unit/timer properties through stub-safe, read-only
  systemd queries; keep unavailable systemd state distinct from inactive state.
- Run `install.sh --doctor` read-only for each canonical project and preserve
  both its exit status and structured `DOCTOR` findings.
- Resolve the event directory from the installer-owned unit environment when
  present; otherwise use the public fallback and record which path rule won.
- Parse exact event statuses/reasons and timestamps over the requested window;
  do not inherit the collector's fail/abort conflation.
- Dedupe incidents by `incident_id`; retain the newest consolidated incident
  facts and distinguish event absence from zero incidents.
- Count release critique findings while separately surfacing spawn failures,
  delivery failures, and budget deferrals.
- Adapt existing FYI/usage/Caddy/incident-file collector evidence without
  treating missing sources as zero.
- Resolve open proposals from persisted `status:"open"` result entries minus
  decision IDs; carry evidence/signal IDs, age, type, severity, and incident
  linkage when present.
- Read but never invoke existing Overseer results; mark their age and
  `claim_kind=assessment`.
- Prove the full inspect command is read-only by snapshotting fixture project
  trees, ledgers, results, event files, and unit manifests before/after.

**Gate classes:** Shell scripts · bats · Public-repo hygiene · Delegation
contract.

**Observable DoD:** synthetic fixtures produce exact health/attention totals;
`abort` remains distinct from `fail`; one missing source is explicitly
unavailable while a present-empty source is zero; one decided proposal is
absent and one open proposal remains; before/after snapshots are identical.

### Phase 3 — Effectiveness and explainable Shipyard-core priorities (5 pts)

**Goal:** answer “is Shipyard useful here?” and “where should the next core PR
focus?” without fabricating certainty.

**Delegation:** subagent — implement the effectiveness states and deterministic
priority rules against synthetic cross-project evidence; return every rule
covered, ordered fixture output, human/JSON parity proof, test exits, and
blockers.

**Work:**

- Add `measured|partial|unmeasured` records for the four presentation floors,
  critique actionability, and available delegation/harness-use evidence.
- Invoke the existing delegation reporter only through its read-only JSON
  surface; treat absence/error/Hermes unsupported as explicit coverage gaps.
- Implement the six fixed priority categories and deterministic within-category
  ordering from L11-L13.
- Require every priority to carry its rule, operands, source evidence,
  `claim_kind`, confidence basis, limitations, and core-vs-project scope.
- Pin cross-project recurrence on stable exact rule/reason identifiers; forbid
  free-text semantic clustering and opaque numeric scores.
- Keep project-only candidates in `attention`; promote to `shipyard-core`
  priorities only under L14's direct-core or cross-project rule.
- Render the human summary exclusively from the completed JSON document:
  headline fleet state, operator attention, effectiveness gaps, and top
  Shipyard-core priority candidates with “why this ranked here.”
- Add immutable synthetic JSON shape/order fixtures or equivalent structural
  assertions so agents can safely consume `--json`.

**Gate classes:** Shell scripts · bats · Public-repo hygiene · Delegation
contract.

**Observable DoD:** an exact multi-project fixture yields the locked category
and tie-break order; a project-only app failure is not mislabeled core; missing
linkage is `unmeasured`, not zero; every human priority line maps to the same
JSON priority/evidence; no model/network/write command is called.

### Phase 4 — Cross-harness contract, canonical docs/deck, and real-fleet proof (2 pts)

**Goal:** make the command discoverable and accurately documented for humans,
Claude, Codex, and Hermes, then prove it against the actual installed fleet.

**Delegation:** inline (documentation/skill-contract edits and final gate
commands must be read and verified by the orchestrator; exception 2).

**Work:**

- Update `skills/shipyard/SKILL.md` triggers, usage, subcommands, and result
  reading so each harness calls the deterministic core rather than recreating
  the analysis.
- Update the existing `/shipyard` section in `README.md`.
- Update the existing `/shipyard` presentation node in
  `docs/deck-editorial.json`; regenerate `docs/shipyard-data.json` because the
  skill frontmatter description changes.
- Add/extend install tests proving both discovery roots resolve the same
  `shipyard` skill implementation and the generated `AGENTS.md` bridge exposes
  it without a harness-specific fork.
- Run `inspect` and `inspect --json` on the actual installed fleet; validate
  JSON structurally; manually compare the human headline/priorities with their
  JSON source records.
- Demonstrate read-only behavior on the real system by recording project/unit
  state before and after and by auditing the command's invoked operations.
- Preserve `install.sh` manifests/unit generation and all existing
  `status`/`add-specialist`/`learn` behavior.

**Gate classes:** Shell scripts · bats · Deck coupling · Public-repo hygiene ·
Delegation contract. Served-app and systemd-unit-generation gates do not apply
because no service or generated unit changes.

**Observable DoD:** all three harness discovery paths lead to the same command;
README and deck claims match the real output; generated deck data is current;
the real fleet report is valid and evidence-linked; the full project battery is
green.

## Testing Strategy

- Add `tests/shipyard-inspect.bats` as the focused contract suite. The first
  inspect invocation/JSON-schema case must be shown failing against pre-change
  code before implementation.
- Use `quartet_setup`, redirected `HOME`, `make_fixture_project`, and
  `make_stub`/`make_stub_script` from `tests/helpers.bash`; no test reaches the
  real systemd user instance, GitHub, network, model, event store, or transcript
  store.
- Hand-author synthetic service manifests, JSONL events, decisions, proposals,
  usage/FYI records, Overseer results, and delegation-report output. Never copy
  or sanitize private live data into fixtures.
- Assert exact JSON fields/counts/order, explicit unavailable-vs-empty states,
  exit 0/2/3 semantics, and unchanged before/after fixture snapshots.
- Preserve existing `tests/shipyard-status.bats`; no-argument remains `status`.
- Project gates:
  - `bats tests/`;
  - shell syntax and relevant Python byte-compile;
  - `bash scripts/leak-check.sh` after every new file is tracked or intent-added;
  - `bash scripts/check-deck-fresh.sh` and deck completeness/render checks once
    the skill/deck contract changes;
  - read-only real-system invocation in the canonical checkout.

## Roll-up Definition of Done

- [ ] `shipyard inspect` discovers every and only installer-owned Shipyard
      project on the system, deduped by canonical path; skills-only and
      arbitrary `CODE_ROOT` checkouts are explicitly outside discovery.
- [ ] The existing no-argument/`status`, `add-specialist`, and `learn` behavior
      and exit semantics are unchanged.
- [ ] Default output is a concise whole-fleet operator report; `--json` emits
      the stable `schema_version:1` source document; human output is rendered
      only from that document.
- [ ] `--days N` uses an exact UTC window and rejects non-positive/non-integer
      input with exit 2.
- [ ] No eligible fleet exits 3; unhealthy/degraded fleet data still produces a
      report and exits 0.
- [ ] Health includes installed roles/unit state, doctor drift, exact job
      statuses/reasons, deduped incidents, critic failures/findings, and source
      freshness/coverage without merging benign aborts into failures.
- [ ] Attention includes open-undecided proposals and direct operator-relevant
      failures/gaps, with decided proposals suppressed and no action taken.
- [ ] Every presentation-defined effectiveness outcome is reported as
      `measured`, `partial`, or `unmeasured` with target, evidence, and reason;
      missing linkage is never counted as success or zero.
- [ ] Priorities use the six locked categories and deterministic tie-breakers;
      every candidate exposes rule, evidence, claim kind, confidence basis,
      limitations, and scope; no opaque score or free-text semantic clustering
      exists.
- [ ] Project-only app problems remain operator attention; only direct-core or
      exact cross-project recurrence becomes a Shipyard-core next-PR candidate.
- [ ] Existing Overseer results are read but never refreshed; delegation
      reporting is read-only; unsupported Hermes measurement is explicit.
- [ ] The command performs no writes, notifications, approvals, ticket
      creation, systemd state changes, model calls, or network calls, proven by
      hermetic command stubs plus before/after snapshots.
- [ ] Claude, Codex, and Hermes reach the same installed skill/core; no
      harness-specific inspect implementation or global binary is added.
- [ ] `skills/shipyard/SKILL.md`, `README.md`, and the existing deck node
      document the shipped behavior; generated deck data is current.
- [ ] Focused RED-first cases and the full `bats tests/`, syntax/compile,
      leak-check, deck freshness/completeness, and optional render gates pass;
      real-fleet human/JSON output is structurally and semantically compared.
- [ ] Every phase's Ledger entry records its actual `builder:` line and gate
      evidence; the working tree is clean after each committed phase.

## Boundaries

### Always

- Operate read-only and locally; report evidence and limitations before advice.
- Use installer-owned manifests as the fleet authority and canonicalize every
  accepted runner/project path.
- Produce human and JSON views from one versioned document.
- Keep facts, deterministic derivations, and persisted assessments visibly
  distinct.
- Preserve existing command behavior and the 0/2/3 exit contract.
- Use hermetic synthetic fixtures and the project's red-first test convention.

### Ask first

- Any event/result schema change to make an unmeasured effectiveness outcome
  measurable.
- Any new network/hub/ICE API integration, model-assisted semantic grouping, or
  automatic ticket/proposal creation.
- Any change that writes global configuration, installs a PATH binary, or
  alters systemd unit generation.
- Any outward-facing publication beyond updating the existing canonical README
  and presentation claims through their normal reviewed flow.

### Never

- Start, stop, restart, enable, disable, or reload a unit; approve/deny a
  proposal; edit a project; append an event/decision; notify the owner; or spend
  model tokens.
- Scan arbitrary repositories under `CODE_ROOT` and call them installed.
- Represent missing/unlinked data as zero, success, or health.
- Use free-text semantic clustering, an opaque composite score, or a model
  judgment to rank priorities.
- Add a daemon, dashboard, database, package dependency, top-level module
  boundary, separate harness implementation, or second global CLI.

## Dependencies

- No external dependency. Required local tools (`bash`, `python3`, `jq`,
  `systemctl`) are already Shipyard requirements.
- The command may consume but does not require existing event streams, result
  files, decisions, Overseer results, or transcript reports; absent inputs
  degrade explicitly through `coverage`.
- No ticket blocks this work. The other pending ticket's outcome phase is
  time-deferred and does not touch this command surface.

## Risks & Mitigations

- **A fleet scan accidentally includes unrelated/stale units.** Mitigation:
  canonical runner-root ownership check, canonical project-path dedupe, and
  hermetic other-root/duplicate-theme fixtures.
- **“Unhealthy” becomes an unauditable opinion.** Mitigation: health facts keep
  exact status/reason/source records; assessments are labelled; unhealthy data
  does not overload process exit.
- **A missing source looks like a clean fleet.** Mitigation: explicit coverage
  entries and `available/reason/newest_ts/records_read`; unavailable never
  defaults to zero.
- **The priority list sends work to the wrong repo.** Mitigation: direct-core or
  exact cross-project scope rule; project-local candidates remain attention;
  each recommendation explains its rule/evidence/limitations.
- **Human and agent output drift.** Mitigation: one JSON document, one human
  renderer, stable schema version, and parity tests.
- **Inspecting has side effects through reused tools.** Mitigation: invoke only
  documented read-only surfaces, never refresh Overseer, stub every subprocess,
  and snapshot fixture/real state before and after.
- **A large transcript/event history makes the command slow.** Mitigation:
  bounded 7-day default, daily-file selection, per-source counts/freshness, and
  no model/network calls. Polish must set a measured local runtime ceiling from
  the real fleet baseline rather than inventing one.
- **Public docs promise metrics the data cannot prove.** Mitigation: docs name
  `measured|partial|unmeasured`; real-fleet verification checks every headline
  against its source record before publication.

## Out of scope

- Replacing the ICE dashboard or Daily Dispatch.
- Approve/Deny or any other action-taking CLI mode.
- Automatic repair, proposal drafting, ticket writing, PR creation, or
  “one-click” remediation.
- Changing runner behavior, event schemas, unit generation, timers, budgets,
  gates, or notification policy.
- Adding proposal→ticket→build lineage solely to improve this report; the CLI
  reports that instrumentation gap for a later stamped PR.
- Native host-managed/global skill-picker entries; repository-local shared-skill
  discovery remains the contract.
- Historical reconstruction when source IDs or events do not exist.

## Ledger

_Appended by `execute-ticket`; every phase records `builder:` and exact gate
evidence._

---

Run it through `polish-ticket`; with no open user decision, its auto-gate
proceeds to `execute-ticket`.
