# Shipyard Fleet Inspect CLI: health, operator focus, and evidence-backed next-PR priorities

- **Created:** 2026-07-29
- **Owner:** wabbazzar
- **Status:** Complete — built and verified 2026-07-29 UTC
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 20 (7 phases, each within the 5-point cap)
- **Refs:** `skills/shipyard/{SKILL.md,shipyard.sh}`, `install.sh --doctor`,
  `agents/design/collectors.sh`, `scripts/delegation-report.py`,
  `docs/deck-editorial.json`, `.agents/gates.md`

## Goal

Add a current-user-fleet, read-only `shipyard inspect` command to the existing
`/shipyard` operator console. From any project carrying the shared Shipyard
skill, a human, Claude, Codex, or Hermes must be able to ask one deterministic
command:

```bash
bash .claude/skills/shipyard/shipyard.sh inspect
bash .claude/skills/shipyard/shipyard.sh inspect --json
```

The command discovers matching crew service manifests attached to the same
resolved Shipyard core root for the current Unix user's systemd instance,
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
| Matching current-user fleet | user service manifests whose canonical runner belongs to this core root | unit identity and runner realpath checks in `install.sh:149-160`, `:193-216`, generated `WorkingDirectory`/`ExecStart` in `:714-724` |
| Configured safety posture | each accepted project's `.agents/config.toml` | local runner defaults and gates in `agents/{build,release,medic}/runner.sh`; public contract in `README.md:180-188` |
| Install integrity | `install.sh --doctor --project DIR` | one `DOCTOR <class>: <detail>` per finding, exit 0 clean / 1 drift (`install.sh:166-172`, `:373-378`) |
| Jobs, incidents, critiques | append-only event JSONL | canonical events documented in `README.md:420-429`; existing aggregation in `agents/design/collectors.sh:85-121` |
| Feedback and usage | per-project FYI and usage JSONL | `agents/design/collectors.sh:123-158` |
| Open proposals | configured result-dir design result minus `data/decisions.jsonl` | result/display/decision lifecycle in `agents/design/runner.sh:171-188`, `:228-241`, `:395-427` |
| Existing fleet assessment | `tmp/overseer-result.json` | persisted `{healthy,status,summary,findings,ts}` in `agents/overseer/runner.sh:26-31`, `:170-190` |
| Harness/pipeline use | separate `scripts/delegation-report.py --source claude|codex --since … --json` calls | read-only lower-bounded report in `scripts/delegation-report.py:620-695`; no `--until`, so coverage is partial |

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

1. **Whole fleet:** inspect the entire current-user fleet attached to this
   Shipyard core root, not only the current project; L3-L4 record the
   observable boundary and spoof limitation.
2. **Strictly read-only:** report and recommend; never take an action.
3. **Two renderings, one document:** concise human output by default and stable
   JSON for agents/automation.

## Objective

On a system with one or more matching Shipyard crew manifests, `shipyard
inspect` must produce within one local invocation a truthful, deterministic
assessment of the current user's fleet attached to this core root over a
declared time window. The assessment must:

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
| L1 | Extend the existing `/shipyard` surface with `inspect`; do not install a second global binary. | `shipyard.sh` is already the shared deterministic core consumed by three harnesses through two discovery roots. |
| L2 | `inspect` is fleet-wide by definition. `status` remains the existing per-project/default command. | Whole-fleet scope is owner-confirmed; preserving `status` avoids a breaking change. |
| L3 | Scope is the **current Unix user's** systemd user-unit directory and only `.service` manifests whose canonical `WorkingDirectory` exists, exactly equals the canonical `--project` argument in `ExecStart`, and whose canonical runner resolves under this invocation's `QUARTET_DIR/agents/<canonical-role>/runner.sh`; dedupe by canonical project path and role. | Avoids arbitrary `CODE_ROOT` checkouts, mismatched/spoofed project targets, other Unix accounts, and another Shipyard checkout. Generated units carry no ownership/version marker, so call these “matching eligible manifests,” not cryptographically proven installer ownership. |
| L4 | A skills-only checkout with no matching service manifest is not a fleet member; a byte-matching spoofed service is indistinguishable in v1. Report both discovery limitations in metadata/docs. | There is no authoritative system-wide registry or manifest ownership marker. |
| L5 | Human output is a rendering of the same in-memory document returned by `--json`; it is not assembled through a separate data path. | Prevents agents and humans receiving contradictory assessments. |
| L6 | JSON carries `schema_version: 1`; new fields may be additive, but removal/renaming is a versioned compatibility change. | Gives Claude, Codex, Hermes, and shell callers a stable contract. |
| L7 | Capture `inspection_started_at` once in UTC. Default `--days 7` means the rolling 168-hour half-open interval `[started_at - 7×86400s, started_at)`; positive integer `--days N` is required. `SHIPYARD_INSPECT_NOW` is a documented test-only RFC3339 clock injection and invalid values exit 2. | Makes fixtures deterministic and excludes records appended concurrently after inspection begins. |
| L8 | Exit 0 means a report was produced, including a report with unhealthy findings; exit 2 means malformed invocation/config; exit 3 means no eligible Shipyard installation. | Health belongs in report data, not process failure. It preserves the console's load-bearing 0/2/3 contract. |
| L10 | Implement structured aggregation in a stdlib-only helper inside `skills/shipyard/`, invoked by `shipyard.sh`; no package or service is introduced. | Complex parsing/ranking needs structured code, while the whole skill directory is already installed by symlink. |
| L11 | Fixed priority categories, in order: `confirmed_failure`, `human_gate`, `recurring_failure`, `evidenced_opportunity`, `instrumentation_gap`, `hygiene`. | Mirrors the design loop's failure/repeated-ask/hot-path/blind-spot vocabulary without an opaque composite score. |
| L12 | Every priority declares `claim_kind: fact|derived|assessment`, `rule_id`, evidence operands, source records, `confidence_basis`, and `limitations`. | A heuristic must explain itself and must never be presented as ground truth. |
| L13 | Within one category, order by direct evidence count descending, newest evidence timestamp descending, then stable project/signal ID. | Deterministic, inspectable ordering; no model or hidden weights. |
| L14 | Evidence directly naming the core root/component may be `shipyard_core`; exact recurrence across projects is only a `core_candidate` assessment, never proof of a core defect. Project-local app problems remain `project_local` attention. | Two projects can share a provider outage, dirty tree, or budget exhaustion without a Shipyard bug. |
| L15 | Existing Overseer output is read if present but never refreshed. It is labelled an `assessment`, not a fact. | Invoking Overseer would write a result and spend model tokens, violating read-only scope. |
| L16 | North stars may be displayed as context or deterministic tie-break metadata; they never override evidence. | The design contract says the north star ranks but never gates. |
| L17 | Health is non-certifying: `fault_observed|degraded_observed|no_fault_observed|unknown`. A normal inactive oneshot service is not a fault; absent events cannot certify health. | Crew services are `Type=oneshot`, and event logging is fire-and-forget. |
| L18 | Evidence IDs use the exact source locator and canonical JSON rules under `evidence[]`: JSONL/text locators are physical 1-based lines; structured JSON locators are RFC 6901 pointers to the record. Identical duplicate JSONL lines remain separate evidence but share a recurrence key. | Events have no durable event/run ID; IDs must be stable, local, and auditable without inventing lineage. |
| L19 | Recurrence keys are fixed by source: `doctor:<class>`; `job:<role>:<status>:<reason-or-empty>`; `critic:<event>:<reason-or-empty>`; `coverage:<source>:<reason>`; `proposal:<type>:<id>`. Free-text summaries/titles never form a recurrence key. | Pins deterministic grouping and prevents semantic inference. |
| L20 | Source windows are explicit: timestamped event/FYI/usage records use L7; current open proposals/decisions are state, not window-filtered; `medic-incidents-current.json` and Overseer results are state with persisted timestamps; Caddy journal uses L7. Delegation reporters run separately with L7's `--since`, but because they have no `--until` they are always `coverage.state=partial`, `reason=upper_bound_unsupported`, and name their own completion time; records arriving after `inspection_started_at` may be included. Hermes is unsupported coverage. | Existing collectors/reporters mix daily files, unbounded data, mtime, a fixed 24-hour journal, and lower-bound-only transcript filters; v1 must not pretend those are one clock. |
| L21 | “Stale” is source-specific. Collect timer timestamps with `LC_ALL=C TZ=UTC`; accept only systemd's exact `"%a %Y-%m-%d %H:%M:%S UTC"` form, parse it with Python `datetime.strptime`, attach `timezone.utc`, and serialize RFC3339 `YYYY-MM-DDTHH:MM:SSZ`. Empty, `n/a`, or nonmatching values become `null` and make timer freshness `unknown`. A timer is `stale` only when it is active and its parsed next trigger is more than 300 seconds before `inspection_started_at`; it is `fresh` when active with a parsed next trigger at/after that grace boundary, otherwise `unknown`. Persisted assessments are not called stale without a declared cadence; old FYI/usage is quiet history, not automatically stale. | Pins host-independent timestamp normalization; one generic age threshold would still produce false alarms. |
| L22 | `autonomous` is `null` when config cannot establish it. Overseer is `not_applicable/absent/not_autonomous` only for observed `false`, `unknown/unavailable/config_unknown` for `null`, `applicable/absent/no_result` for observed `true` with no result, and an `assessment` when a result is present for observed `true`. | Overseer intentionally watches only `autonomous=true` projects; unreadable config cannot prove the negative. |
| L23 | Mentat result lookup honors `.paths.result_dir // "tmp"` and both canonical role/display naming; open proposals are state-filtered against `data/decisions.jsonl`. Missing persisted `approval_action` is reported as `null` plus limitation, never reconstructed. | The runner resolves a themed display and currently drops `approval_action` on persistence. |
| L24 | The presentation's four outcome floors are labelled the historical 5-day trial benchmark; critique actionability is labelled the historical 2-week benchmark. `partial` means component evidence exists but the outcome is unprovable and therefore `value:null`, never fractional credit. | These are not continuous 7-day health SLOs, and current result IDs cannot prove all linkage. |
| L25 | Do not call runner `--check-config` from inspect. Locally parse and report the exact safety object under `fleet[]`; an explicit configured `branch` is reported, while remote-derived trunk and runtime recovery proof are `unavailable`. | Trunk detection may query/refresh remote HEAD and self-test mutates fixtures, violating strict local read-only scope. |
| L26 | Read each evidence file only after `inspection_started_at` is captured. The report is a bounded best-effort snapshot, not an atomic transaction; record that limitation. | Fleet timers may append concurrently. |
| L27 | Resolve event roots **per project** from that project's accepted manifests: zero nonempty values → core fallback; one unique value → use it; more than one → that project's events coverage is `error/mixed`. Different projects may legitimately use different consistent roots. Scan each unique root once. Attribute an event to a project only when `.svc` exactly equals one accepted service-manifest stem (basename without `.service`) for that project; zero/multiple matches never affect project metrics and are counted by global `events_attribution` coverage. | Fleet installs may route projects to different hubs, and a shared hub contains multiple projects. `project` is absent from many end events, but the emitted `svc` is the installed service basename and is the runner's own budget boundary. |
| L28 | In v1 the five presentation outcome benchmarks can be only `partial` or `unmeasured`; current persisted lineage/actionability schemas cannot prove a measured outcome. `measured` is used by the two delegation cohorts when their reporters succeed. | Prevents synthetic or disconnected proposal/build/decision facts from earning outcome credit. |
| L29 | Caddy domain is the lowercase hostname of the first configured HTTP(S) medic probe URL. Query strings and fragments are removed before path aggregation/evidence; no query value enters output. | Raw request URIs can contain secrets and are not stable path keys. |
| L30 | A project decision is valid only when a JSONL object has a nonempty string `proposal_id`, `decision` exactly `approve|deny`, and an RFC3339 `ts`. Only valid records suppress a matching open proposal. Malformed/unknown records are counted and do not suppress; conflicting valid decisions for one ID make decisions coverage `partial/mixed` but still suppress that ID. | Pins the dispatch mirror schema and prevents arbitrary ledger text from silently hiding operator work. |
| L31 | Daily budget consumption uses `[00:00:00Z on inspection_started_at's UTC date, inspection_started_at)`, not L7, and is reported by independently enforced consumer: `design_runner`, `build_runner`, `release_runner`, `release_shoulder_critic`, `medic_runner`, `scribe_runner`. Attribute every measurable consumer by exact service stem using L27's event root. Design charges `design.*.tokens`; shoulder charges `release.critique.tokens`; the other runners charge `job.end.tokens`. Expose the gate operand the current code actually sums: design and shoulder use `unscoped_event_root`, while the four other runners use `exact_service`. Design's gate root is L27's explicit manifest root or core fallback. Build/release/medic/scribe use an explicit manifest `QUARTET_EVENTS_DIR`, but when absent their literal gate root is `/nonexistent`; inspect the same `/nonexistent/<UTC-date>.jsonl` if present (including its `fromjson?` behavior), otherwise the operand is zero. This `unset_sentinel` root differs from emitted events' core fallback. Shoulder root is `configured` only from an exact matching current-user critic-watch service manifest with explicit `QUARTET_EVENTS_DIR`, `project_default` only when that manifest explicitly pins `<project>/data/events`, otherwise `unknown`; never infer it from crew manifests or `.agents/shoulder.env`. Unknown shoulder roots produce null operands/fractions. Both same-day fractions use the consumer's configured daily cap. | A seven-day numerator divided by a daily budget is dimensionally false; release runner and shoulder critic enforce separate caps; four unset runner gates and runtime shoulder overrides diverge from event emission; proven operand mismatches are actionable Shipyard evidence. |
| U1 | **No config key.** Explicitly invoking `shipyard inspect` is the opt-in; unset/no-argument behavior remains `status`. | Owner answer on 2026-07-29: “no config”. The gate file limits config-gated additivity to runner/installer changes; this explicit read-only console command changes neither. |
| U2 | After every local gate passes, **push `main`** and verify the configured deck/mirror publication cascade. | Owner answer on 2026-07-29: “push”. This explicitly authorizes the outward-facing publication named by the ticket. |

### Open decisions

**None.**

### User-decision class

**None. U1 and U2 are locked above.**

**Auto-gate: PROCEED.** The implementation is decision-complete.

## Versioned Output Contract

Phase 1 does **not** get to design this contract. It implements the following
field names, types, nullability, enums, ordering rules, and truth semantics.
`tests/fixtures/shipyard-inspect/full-schema-v1.json` is a synthetic immutable
golden containing every enum and nullable branch. JSON serialization is UTF-8,
two-space indented, newline-terminated, with keys emitted in the order below;
arrays use their stated deterministic sort.

### Top level

```json
{
  "schema_version": 1,
  "meta": {},
  "coverage": [],
  "evidence": [],
  "fleet": [],
  "attention": [],
  "effectiveness": [],
  "priorities": [],
  "summary": {}
}
```

No top-level key is optional. Unknown/additive fields are permitted within
schema version 1; removing, renaming, retyping, or changing nullability requires
schema version 2.

### `meta`

| Field | Type | Contract |
|---|---|---|
| `inspection_started_at` | RFC3339 UTC string | Captured once before any evidence read; also the exclusive window end. |
| `window_start_at` | RFC3339 UTC string | `inspection_started_at - days×86400s`, inclusive. |
| `window_end_at` | RFC3339 UTC string | Equal to `inspection_started_at`, exclusive. |
| `window_days` | positive integer | Default 7. |
| `core_root` | absolute canonical string | Resolved `QUARTET_DIR`. |
| `unit_dir` | absolute canonical string | Current user's systemd user-unit directory. |
| `scope` | string enum | Exactly `current_user_matching_core_root`. |
| `rule_version` | string | Exactly `shipyard-inspect-v1`. |
| `project_count` | nonnegative integer | Length of `fleet`. |
| `role_count` | nonnegative integer | Unique accepted project+role pairs. |
| `discovery_limitations` | string array | Always includes skills-only exclusion, indistinguishable matching spoof, current-user scope, and non-atomic snapshot. |

`meta` never claims “all installations on the machine.”

### `coverage[]`

One record exists for every applicable or attempted source per project, plus
global event-attribution and delegation sources:

| Field | Type |
|---|---|
| `project_id` | string or `null` for global source |
| `source` | `manifest|config|systemd|doctor|events|events_attribution|fyi|usage|caddy|incident_state|proposals|decisions|overseer|delegation_claude|delegation_codex|delegation_hermes` |
| `state` | `available|partial|unavailable|error|not_applicable` |
| `reason` | `ok|missing|unreadable|malformed|missing_dependency|systemd_unavailable|unsupported|upper_bound_unsupported|not_autonomous|no_domain|no_result|stale|command_failed|mixed` |
| `newest_ts` | RFC3339 UTC string or `null` |
| `records_total` | nonnegative integer |
| `records_valid` | nonnegative integer |
| `records_invalid` | nonnegative integer |
| `records_out_of_window` | nonnegative integer |
| `records_unattributed` | nonnegative integer |
| `records_ambiguous` | nonnegative integer |
| `limitations` | string array |

Sort by `project_id` (`null` first), then the source enum order above.
All record counters are present; non-event sources set attribution counters to
zero. The single global `events_attribution` row aggregates each unique event
root once: `records_valid` means assigned to exactly one eligible project,
`records_unattributed` means a valid `.svc` matched none,
`records_ambiguous` means it matched more than one, and malformed/missing `.svc`
increments `records_invalid`. Per-project `events` rows count only records
attributed to that project, so shared hubs never duplicate or cross-contaminate
metrics. Malformed JSON, missing timestamps on timestamp-governed inputs, and reporter
malformed-boundary/timestamp counts make a source `partial`; they never vanish
behind `fromjson?`. A present-empty source is `available` with all record counts
zero. A missing source is never represented as an available zero.

### `evidence[]`

Every attention, effectiveness, priority, and fleet-state reason refers to an
entry here by ID:

| Field | Type | Contract |
|---|---|---|
| `id` | 20-character lowercase hex string | Derived exactly by L18. |
| `project_id` | string or `null` | Stable project ID, not display name. |
| `source` | coverage source enum | Origin adapter. |
| `claim_kind` | `fact|derived|assessment` | Persisted model outputs/proposal severity are assessment. |
| `kind` | stable string | E.g. `job_end`, `doctor_finding`, `open_proposal`. |
| `observed_at` | RFC3339 UTC string or `null` | Source timestamp; never inspection time substituted for missing source time. |
| `source_ref` | string | Exact registry form below; runtime uses canonical absolute paths and fixtures use stable synthetic `/fixture/...` paths. |
| `recurrence_key` | string or `null` | One of L19's exact forms. |
| `fields` | JSON object | Minimal operands used by rules; never raw feedback/transcript bodies. |
| `limitations` | string array | Empty when none. |

Sort by `id`. Source records with raw user text, transcript content, or secrets
must be summarized into non-content counts/IDs; inspect never prints those
bodies.

For all parsed JSON, reject duplicate object keys and non-finite
`NaN|Infinity|-Infinity` constants as malformed. The following registry is
closed for schema v1. `fields` is exactly the listed operand object: every key
is present, missing values are JSON `null`, arrays are deduped/sorted, unknown
source keys are discarded, and no extra key is permitted. Raw feedback,
transcript, rationale/evidence, incident/Overseer summary, decision reason, and
secrets are represented only by the named presence/count fields.

| `source_kind` discriminator | `kind` | Exact `source_ref` form | Exact `fields` / canonical operand keys |
|---|---|---|---|
| `manifest` | `manifest_identity` | `file:<service-path>:pointer:/` | `service_stem,role,project_path,working_directory,runner,event_root_env` |
| `manifest` | `shoulder_watcher_identity` | `file:<watcher-service-path>:pointer:/` | `service_stem,project_path,working_directory,runner,event_root_state,event_root` |
| `config` | `config_posture` | `file:<config-path>:pointer:/` | `autonomous,can_merge,allow_no_ci,forbidden_paths,release_verify_gate,configured_branch,test_cmd_configured,typecheck_configured,daily_escalation_cap,budget_tokens_daily_by_role,max_open_proposals,shoulder_auto_wire` |
| `systemd` | `unit_property` | `unit:<unit-name>:property:<property>` | `unit,role,property,value` |
| `doctor` | `doctor_finding` | `command:doctor:<project-id>:finding:<1-based-output-ordinal>` | `class,detail` |
| `event` | `job_end` | `file:<event-path>:line:<n>` | `svc,role,status,reason,mode,duration_s,tokens` |
| `event` | `incident_event` | `file:<event-path>:line:<n>` | `incident_id,event,source,surface,probe,http_status,restart_action,outcome,summary_present` |
| `event` | `critique_event` | `file:<event-path>:line:<n>` | `svc,event,source,block,warn,note,files,tokens,reason,attempts` |
| `event` | `design_control_event` | `file:<event-path>:line:<n>` | `svc,event,proposal_id,type,severity,reason,tokens,tokens_used,budget,open,cap` |
| `event` | `budget_control_event` | `file:<event-path>:line:<n>` | `svc,event,source,consumer,reason,tokens_used,budget` |
| `fyi` | `fyi_request` | `file:<fyi-path>:line:<n>` | `id,ts,text_present` |
| `usage` | `usage_beacon` | `file:<usage-path>:line:<n>` | `ts,action,path` |
| `caddy` | `caddy_path_count` | `command:caddy:<project-id>:path:<sha256(domain+NUL+path)[:12]>` | `domain,path,requests,window_start_at,window_end_at` |
| `incident_state` | `incident_state` | `file:<incident-path>:pointer:/<index>` | `incident_id,source,surface,detected_at,probe,http_status,restart_action,outcome,summary_present` |
| `proposal` | `open_proposal` | `file:<result-path>:pointer:/proposals/<index>` | `id,type,title,severity,status,signal_ids,ts,approval_action_present` |
| `decision` | `decision` | `file:<decision-path>:line:<n>` | `proposal_id,decision,ts` |
| `overseer` | `overseer_assessment` | `file:<overseer-path>:pointer:/` | `healthy,status,findings_count,ts,summary_present` |
| `delegation` | `delegation_cohort` | `command:delegation:<claude-or-codex>:aggregate` | `source,sessions,turns,agent_calls,zero_agent_sessions,zero_agent_pct,malformed_records,malformed_boundaries,malformed_timestamps,reporter_completed_at` |
| `coverage` | `coverage_gap` | `derived:coverage:<project-id-or-global>:<coverage-source>` | `project_id,source,state,reason,records_total,records_valid,records_invalid,records_out_of_window,records_unattributed,records_ambiguous` |

`config_posture.budget_tokens_daily_by_role` is exactly an object with
`design,build,release,medic,scribe` keys and no others. For available config,
each value reproduces the runner rule: a TOML integer `>=0` is itself; a TOML
string matching ASCII `^[0-9]+$` is its base-10 integer value; absent/null,
boolean, float, negative integer, or any other value becomes `1000000`. For
unavailable config all five values are `null`.
`release_shoulder_critic` uses the `release` value and does not add a sixth map
key.

Event routing is mutually exclusive and evaluated by exact string equality;
one physical line creates at most one evidence row:

| Evidence kind | Exact accepted event routing |
|---|---|
| `job_end` | `event=="job.end"` |
| `incident_event` | `event` is one of `medic.incident`, `medic.incident.detected`, `medic.incident.classified`, `medic.incident.frozen`, `medic.incident.resolved`, `medic.incident.repair_proposed`, `medic.action.restart` |
| `critique_event` | `event` is one of `release.critique`, `release.critique.delivery_failed`, `release.critique.spawn_failed` |
| `design_control_event` | `event=="design.proposal.opened"`, or `event=="design.proposal.skipped" and reason=="open_cap"` |
| `budget_control_event` | exactly one of: `design.proposal.skipped/budget`; `build.skipped/budget`; `release.skipped/budget`; `release.critique.skipped/budget` with `source=="shoulder"`; `medic.skipped/budget`; `scribe.skipped/budget` |

In the last row, `event/reason` are the slash-separated pair and `consumer` is
respectively L31's six consumer names. Other events—including
`job.start`, `release.stall.retry`, `release.critique.skipped/empty_diff`, and
unknown skip reasons—affect coverage counts only. No fallback prefix or regex
routing is allowed.

The `evidence[].source` mapping is exact: like-named discriminators map to the
same coverage source; `event→events`, `proposal→proposals`,
`decision→decisions`, `delegation→delegation_<cohort>`, and `coverage` uses the
operand's own coverage `source`. The only v1 event evidence kinds are the five
event rows above. Events not
needed by a v1 metric remain coverage records but do not become evidence.
`title` is persisted proposal assessment text and may be shown; its rationale,
evidence, and user-source bodies may not. Paths in usage/Caddy operands are
query/fragment-free per the adapters. `summary_present` and
`approval_action_present` are booleans. Numeric operands accept only finite,
nonnegative values where their metric contract requires that; invalid values
remain coverage and the operand is `null`.

Define `canonical_operand_json` exactly as Python
`json.dumps(fields, sort_keys=True, separators=(",", ":"),
ensure_ascii=False, allow_nan=False)`. Every evidence ID, for files, commands,
properties, and derived coverage alike, is exactly:

```text
sha256(
  source_kind + NUL + source_ref + NUL + canonical_operand_json
)[:20]
```

Concatenate UTF-8 bytes, use one `0x00` byte for each `NUL`, take lowercase
`hexdigest()[:20]`, and reject source strings containing NUL. The Caddy
source-ref suffix uses the same byte/NUL rules and 12 hex characters.
File paths inside `source_ref` are canonical absolute paths. JSONL/text uses
physical 1-based lines. Structured JSON uses RFC 6901 pointers; current
incidents use `/0`, `/1`, … and proposals use `/proposals/0`,
`/proposals/1`, …. Duplicate JSONL lines therefore get distinct IDs from their
line refs. Fixture tests must calculate, not copy, representative IDs from
this formula and prove that deleting/renaming any operand key fails the golden
while input key order does not change the ID. Adding another evidence kind,
operand key, or discriminator requires schema version 2.

Source adapter details:

- **Events:** apply L27, read only UTC daily `.jsonl` files intersecting L7,
  filter every record by its own RFC3339 `ts`, and attribute by exact accepted
  service stem before any project aggregation. Missing/invalid timestamps or
  `.svc` are invalid global attribution coverage and cannot enter metrics.
- **FYI/usage:** read `<project>/data/fyi-requests.jsonl` and
  `<project>/data/usage/*.jsonl`; apply L7 to each record's `ts`; evidence
  carries IDs/actions/query-free paths and counts, never feedback text.
- **Caddy:** derive L29's domain with stdlib URL parsing and run exactly:

  ```bash
  journalctl --user -u caddy -o json --no-pager \
    --output-fields=__REALTIME_TIMESTAMP,MESSAGE \
    --since <window_start_at> --until <inspection_started_at>
  ```

  Parse each outer journal JSON object, require decimal-microsecond
  `__REALTIME_TIMESTAMP`, and retain it only when the normalized UTC instant is
  in L7's half-open interval; `journalctl --until` being inclusive cannot admit
  a boundary record. Parse `MESSAGE` as the inner Caddy JSON, filter lowercase
  `.request.host` (port removed) to the derived domain, take `.request.uri`,
  remove query/fragment, normalize an empty path to `/`, and aggregate
  `{domain,path,requests}` as
  `kind=caddy_path_count`. A fixture URI
  `/callback?debug=fixture` must produce path `/callback`; the query value must
  not appear anywhere in output. Missing/invalid outer timestamps or inner
  JSON increment invalid Caddy coverage.
- **Current incident state:** read exactly
  `<project>/<paths.result_dir-or-tmp>/medic-incidents-current.json`. It must be
  a JSON array. Its records are current state rather than L7-windowed; use each
  record's persisted `detected_at // ts` when valid, else `observed_at=null`
  plus partial coverage. Do not glob old incident files.
- **Proposals:** read exactly
  `<project>/<paths.result_dir-or-tmp>/<project_name>-<design_display>-result.json`
  and apply L30 to the exact decision ledger in L23.

### `fleet[]`

Sort projects by `project_id`, where:

```text
project_id = sha256(canonical_project_path)[:12]
```

Hash the UTF-8 path bytes and take lowercase `hexdigest()[:12]`.
Each record contains:

| Field | Type |
|---|---|
| `project_id` | 12-character lowercase hex string |
| `project_name` | string from config or directory basename |
| `project_path` | canonical absolute string |
| `autonomous` | boolean or `null` when config is unavailable |
| `state` | `fault_observed|degraded_observed|no_fault_observed|unknown` |
| `state_reason_ids` | evidence-ID array |
| `roles` | canonical role enum array in `design,build,release,medic,scribe` order |
| `units` | unit record array sorted by canonical role |
| `doctor` | doctor object |
| `jobs` | jobs object |
| `incidents` | incident array |
| `critiques` | critiques object |
| `pressure` | pressure object |
| `safety` | safety object |
| `overseer` | overseer object |
| `limitations` | string array |

Unit record:

```json
{
  "role": "release",
  "display": "proctor",
  "service_unit": "example-proctor.service",
  "timer_unit": "example-proctor.timer",
  "on_calendar": "daily",
  "unit_file_state": "enabled",
  "timer_load_state": "loaded",
  "timer_active_state": "active",
  "timer_sub_state": "waiting",
  "timer_stale_state": "fresh",
  "service_load_state": "loaded",
  "service_active_state": "inactive",
  "service_sub_state": "dead",
  "service_result": "success",
  "exec_main_status": 0,
  "last_trigger_at": null,
  "next_trigger_at": null,
  "evidence_ids": []
}
```

Every systemd string property is a string or `null`; `exec_main_status` is an
integer or `null`; `timer_stale_state` is `fresh|stale|unknown`.
`on_calendar` is parsed from the matching timer manifest's `OnCalendar=`
line, without attempting to evaluate calendar syntax. Read runtime properties
with:

```bash
LC_ALL=C TZ=UTC systemctl --user show <timer> \
  -p LoadState -p ActiveState -p SubState -p UnitFileState \
  -p LastTriggerUSec -p NextElapseUSecRealtime
LC_ALL=C TZ=UTC systemctl --user show <service> \
  -p LoadState -p ActiveState -p SubState -p Result -p ExecMainStatus
```

For `LastTriggerUSec` and `NextElapseUSecRealtime`, strip only surrounding
ASCII whitespace, treat empty/`n/a` as `null`, and otherwise require
`datetime.strptime(value, "%a %Y-%m-%d %H:%M:%S UTC")`, then
`.replace(tzinfo=timezone.utc)`. A parse failure records the raw property as
malformed coverage, emits `null`, and does not guess a timezone. The fixture
`Thu 2026-07-30 06:00:00 UTC` must normalize to
`2026-07-30T06:00:00Z`; a CDT/local-time fixture is rejected.

A `Type=oneshot` service with `ActiveState=inactive`, `SubState=dead`,
`Result=success` is normal. `ActiveState=failed` or `Result=failed` is a direct
fault. A disabled/inactive/missing timer is a direct fault. A missing user bus
is `systemd unavailable`, not a false fault. Timer staleness follows L21
exactly.

Doctor object:

```json
{
  "state": "clean",
  "exit_code": 0,
  "findings": [
    {"class": "unit", "detail": "redacted fixture detail", "evidence_id": "00000000000000000000"}
  ]
}
```

`state` is `clean|drift|unavailable|error`; `exit_code` is integer or `null`.
Exit 0 → clean. Exit 1 plus at least one parseable
`DOCTOR <class>: <detail>` line → drift. A missing
`git|gh|claude|jq|python3|systemctl` dependency → unavailable. Exit 1 without a
parseable finding, or any unexpected exit → error. Inspect must not alter doctor
output or convert unavailable/error to clean.

Jobs object:

```json
{
  "by_status": {"ok": 0, "fail": 0, "partial": 0, "abort": 0, "skipped": 0, "other": 0},
  "by_reason": {},
  "last_end_at": null,
  "duration_seconds_p50": null,
  "duration_seconds_p95": null,
  "evidence_ids": []
}
```

Durations are numbers or `null`, calculated only from valid numeric
`duration_s >= 0` operands. Sort ascending and use the nearest-rank definition:
for percentile `p` and `n>0`, select 1-based rank `ceil(p*n)` (array index
`ceil(p*n)-1`), with no interpolation or rounding; no valid durations → `null`.
Fixtures pin odd and even samples for p50/p95. Statuses remain distinct,
including `skipped`. Unknown statuses increment `other` and preserve their
exact value in evidence fields.

Incident records are deduped by nonempty `incident_id`, sorted by
`last_observed_at` descending then ID, and carry:

```json
{
  "incident_id": "id",
  "first_observed_at": null,
  "last_observed_at": null,
  "latest_event": "medic.incident",
  "probe": null,
  "http_status": null,
  "restart_action": null,
  "outcome": null,
  "summary_present": false,
  "evidence_ids": []
}
```

Missing-ID incident-shaped events are invalid coverage records, not distinct
incidents. `summary_present` reports only whether a nonempty persisted summary
exists. The summary value is never emitted or hashed into an output field; add
`incident_summary_redacted` to limitations when it exists.

Critiques object:

```json
{
  "block": 0,
  "warn": 0,
  "note": 0,
  "files": 0,
  "tokens": 0,
  "spawn_failed": 0,
  "delivery_failed": 0,
  "budget_deferred": 0,
  "evidence_ids": []
}
```

Pressure object:

```json
{
  "budget_deferrals_by_consumer": {
    "design_runner": 0,
    "build_runner": 0,
    "release_runner": 0,
    "release_shoulder_critic": 0,
    "medic_runner": 0,
    "scribe_runner": 0
  },
  "open_cap_deferrals": 0,
  "daily_budget_consumers": [
    {
      "consumer": "release_shoulder_critic",
      "role": "release",
      "applicability": "applicable",
      "gate_scope": "unscoped_event_root",
      "event_root_state": "configured",
      "event_root": "/synthetic/events",
      "attributed_tokens_today": 0,
      "gate_tokens_today": 0,
      "gate_records_invalid_today": 0,
      "configured_daily_budget": 1000000,
      "attributed_fraction_today": 0.0,
      "gate_fraction_today": 0.0,
      "evidence_ids": []
    }
  ],
  "undecided_open_proposals": 0,
  "configured_max_open_proposals": null,
  "open_cap_remaining": null,
  "evidence_ids": []
}
```

The JSON illustration shows one consumer member's shape; actual
`daily_budget_consumers` always has exactly six records in L31's order,
including explicit non-applicable/unknown members.
`budget_deferrals_by_consumer` always has all six consumer keys; each value is a
nonnegative integer when its event source is usable and the consumer is
applicable, otherwise `null`. `open_cap_deferrals` and
`undecided_open_proposals` are nonnegative integers when their governing
event/proposal sources are usable, otherwise `null`.
Runner consumers are `applicable` only when that role is accepted for the
project. `release_shoulder_critic` is applicable when
`.agents/shoulder.env` exists or local config has `[shoulder].auto_wire=true`;
an exact matching watcher manifest also proves applicability. It is `unknown`
when config is unavailable and neither env nor watcher exists, otherwise
`not_applicable`. Applicability is
`applicable|not_applicable|unknown`; non-applicable/unknown numeric fields are
`null`. `gate_scope` is `exact_service|unscoped_event_root|null`.
`event_root_state` is `runner_manifest`, `core_fallback`,
`unset_sentinel`, `configured`, `project_default`, `mixed`, `unknown`, or
`null`;
`event_root` is a canonical absolute path only when the state resolves one,
else `null`. For applicable build/release/medic/scribe consumers with no
manifest `QUARTET_EVENTS_DIR`, use `event_root_state=unset_sentinel`,
`event_root="/nonexistent"`, and reproduce the runner's exact dated-file sum;
missing/unreadable is zero, while a present readable file uses valid
`job.end.tokens` for the exact service. Their attributed operand still uses
L27's core fallback. For shoulder, a matching watcher manifest must have canonical
`WorkingDirectory` equal to the project and exact
`ExecStart=/bin/bash <core>/agents/release/critic-watch.sh --project <project>`;
an explicit canonical `Environment=QUARTET_EVENTS_DIR=...` supplies the root.
For each `Environment=` payload use `shlex.split(..., posix=True)` and accept
exactly one `QUARTET_EVENTS_DIR=<absolute-path>` token across the manifest;
zero, multiple, relative, specifier-bearing, or unparsable values are unknown.
If that explicit value equals canonical `<project>/data/events`, label
`project_default`; another value is `configured`; absent/multiple values or no
matching watcher is `unknown`. Do not inspect process environments.
`attributed_tokens_today` sums only the project's exact `svc`;
`gate_tokens_today` reproduces the current consumer gate's exact scoped or
unscoped event selection, including the literal sentinel behavior;
`gate_records_invalid_today` counts records rejected by inspect's strict v1
parser and is null with an unknown root. It is data-quality context, not an
input to the compatibility operand. Each
fraction is its matching numerator divided by a
positive configured cap, else `null`. This deliberately reveals when one
project’s design/shoulder attributed use differs from its resolved unscoped
gate operand. `budget_deferrals_by_consumer` uses the same six keys; L7 deferral
counts use the exact service stem plus, respectively:
`design.proposal.skipped`, `build.skipped`, `release.skipped`,
`release.critique.skipped`, `medic.skipped`, or `scribe.skipped`, each with
`reason=budget` and the critique additionally `source=shoulder`; this avoids
double-counting paired skipped `job.end` records.
L7 deferral counts
remain the declared historical-window signal and are not divided by a daily
cap. `open_cap_deferrals` is exact-service
`design.proposal.skipped reason=open_cap`.

To reproduce `gate_tokens_today`, do **not** reuse the strict evidence parser.
For the consumer's resolved current-UTC-day file, run the existing two-stage
gate semantics with jq 1.7 compatibility:

1. Missing/non-regular file → integer `0`.
2. Pipe `jq -R 'fromjson?' <file>` into `jq -s <filter>` with pipefail.
3. Use these exact second-stage filters:

   - design:
     `[.[] | select((.event // "") | startswith("design.")) |
     (.tokens // 0)] | add // 0`
   - shoulder:
     `[.[] | select(.event=="release.critique") | (.tokens // 0)] |
     add // 0`
   - build/release/medic/scribe:
     `[.[] | select(.svc==$svc and .event=="job.end") |
     (.tokens // 0)] | add // 0`, with exact accepted service stem as `$svc`.

4. If either jq stage exits nonzero, or command-substitution-style trailing
   newline removal leaves output not matching ASCII `^[0-9]+$`, the effective
   operand is integer `0`; otherwise parse that decimal integer. This covers
   valid non-objects, incompatible token types, fractional/negative sums, and
   downstream jq errors exactly.
5. jq's last-key-wins duplicate-key behavior is intentionally confined to this
   compatibility operand. The same line remains invalid strict coverage and
   cannot create evidence. Add limitation `gate_parser_differs_from_v1` when
   such a line is observed.

Invoke jq with fixed filters/argument arrays and file/stdin pipes, never
interpolate a path or service into shell source. Missing jq makes the consumer
operand/fractions `null` with `missing_dependency`; do not report the runner's
zero because the runner cannot reach normal execution without its earlier jq
config reads.
`undecided_open_proposals` uses L23/L30's current state filter;
`open_cap_remaining=max(0, configured-undecided)` when the cap exists, else
`null`. Budget/open-cap deferrals are pressure, not job failure.

Safety object:

```json
{
  "config_state": "available",
  "can_merge": false,
  "allow_no_ci": false,
  "forbidden_paths": [],
  "release_verify_gate": false,
  "configured_branch": "main",
  "trunk_state": "configured",
  "trunk": "main",
  "trunk_reason": "explicit_config",
  "test_cmd_configured": true,
  "typecheck_configured": true,
  "daily_escalation_cap": 5,
  "evidence_ids": []
}
```

`config_state` is `available|unavailable|error`. When config is available,
`fleet.autonomous` is the top-level boolean `autonomous`, default `false`; a
present non-boolean makes config coverage malformed. When config is unavailable,
`fleet.autonomous=null`.
For an available config, apply runner defaults exactly:
`[medic].can_merge=false`,
`[build].allow_no_ci=false`, `[build].forbidden_paths=[]`,
`[release].verify_gate=false`, and `[medic].daily_escalation_cap=5`;
`test_cmd_configured`/`typecheck_configured` mean nonempty strings. A nonempty
top-level `branch` produces `trunk_state=configured`, that exact `trunk`, and
`trunk_reason=explicit_config`. Without it, do not run trunk detection:
`trunk_state=unavailable`, `trunk=null`, and
`trunk_reason=remote_resolution_not_attempted`. When config is
missing/unreadable/malformed, all gate/trunk/cap scalar fields are `null`, the
path array is empty, `trunk_state=unavailable`, and
`trunk_reason=config_unavailable`; `config` coverage preserves the cause.
This is configured posture, not proof that CI, merge, or recovery succeeds.

Overseer object:

```json
{
  "applicability": "unknown",
  "state": "unavailable",
  "reason": "config_unknown",
  "healthy": null,
  "status": null,
  "summary": null,
  "findings_count": null,
  "assessed_at": null,
  "evidence_ids": [],
  "limitations": []
}
```

`applicability` is `applicable|not_applicable|unknown`; `state` is
`present|absent|malformed|unavailable`; `reason` is
`ok|not_autonomous|config_unknown|no_result|malformed`. Only observed
`autonomous=false` is not applicable and not an instrumentation gap. Unknown
config cannot prove that negative.

Fleet state evaluates in this order:

1. `fault_observed` — direct current doctor drift, disabled/missing timer,
   failed service/result, `job.end status=fail|partial`, failed restart, or
   critic spawn/delivery failure in the declared window.
2. `degraded_observed` — no fault above, but a required primary source
   (`manifest|config|systemd|doctor|events`) is partial/error/unavailable, or
   exact pressure is observed. Budget pressure means at least one non-null
   L7 consumer deferral is greater than zero, or an applicable consumer has
   non-null `gate_tokens_today >= configured_daily_budget >= 0`. Open-cap
   pressure means `open_cap_deferrals > 0`, or non-null
   `undecided_open_proposals >= configured_max_open_proposals >= 0`.
   Ordinary token use below the cap and ordinary open proposals below the cap
   do not degrade health.
3. `no_fault_observed` — all five primary sources are available, doctor is
   clean, expected timers are active/enabled, and no direct fault was observed.
4. `unknown` — evidence is insufficient for the other states.

This is an observation, never a health certificate.

### `attention[]`

Sort by `detected_at` ascending with `null` last, then `id`.

| Field | Type |
|---|---|
| `id` | `att_` + 16 lowercase hex characters |
| `project_id` | string |
| `kind` | `open_proposal|observed_fault|install_drift|owner_decision|coverage_gap` |
| `claim_kind` | `fact|derived|assessment` |
| `title` | string |
| `detected_at` | RFC3339 UTC string or `null` |
| `age_seconds` | nonnegative integer or `null` |
| `severity_advisory` | `low|med|high|null` |
| `approval_action` | string or `null` |
| `evidence_ids` | nonempty string array |
| `limitations` | string array |

Open proposal resolution honors L23 and L30. Read the decision ledger as
physical JSONL; only exact `proposal_id` (not `id`) and exact
`approve|deny` values with a valid timestamp decide a proposal. Invalid rows
increment decision coverage and conflicting valid rows for one ID produce
`partial/mixed`; neither reason text nor other ledger body enters output.
A bogus/unresolved `signal_id` makes the
proposal an `assessment` with a limitation; it cannot become an
`evidenced_opportunity`. Persisted proposals currently lack
`approval_action`, so v1 normally reports `null` plus
`approval_action_not_persisted`.

Attention IDs are:

```text
"att_" + sha256(
  kind + NUL + project_id + NUL + join(",", sort(unique(evidence_ids)))
)[:16]
```

Use L18's UTF-8/NUL/lowercase-hexdigest rules. Input record ordering cannot
change the ID.

### `effectiveness[]`

Sort in the order below. Every record contains:

| Field | Type |
|---|---|
| `key` | stable string |
| `benchmark_label` | string |
| `benchmark_window_days` | integer or `null` |
| `target_operator` | `gte|lte|null` |
| `target_value` | number or `null` |
| `unit` | string |
| `state` | `measured|partial|unmeasured` |
| `value` | number or `null` |
| `components` | JSON object |
| `evidence_ids` | string array |
| `reason` | string or `null` |
| `limitations` | string array |

Required records:

1. `bugs_caught_and_fixed` — historical 5-day trial target `gte 1`.
2. `usage_assessed_projects` — historical 5-day trial target `gte 3`.
3. `features_shipped_end_to_end` — historical 5-day trial target `gte 1`.
4. `consequential_decisions_surfaced` — historical 5-day trial target `gte 1`.
5. `critique_actionability` — historical 14-day target `gte 0.333333`.
6. `execute_ticket_delegation_claude` — no presentation target; reporter facts.
7. `execute_ticket_delegation_codex` — no presentation target; reporter facts.
8. `execute_ticket_delegation_hermes` — `unmeasured`, unsupported in v1.

Per L28, records 1–5 are never `measured` in v1: component facts yield
`partial`, `value:null`, and named missing links; no component facts yield
`unmeasured`, `value:null`. Critique finding counts without an operator
actionability judgment likewise remain partial. Records 6–7 are `measured`
only when their reporter succeeds, otherwise partial/unmeasured as coverage
dictates. Invoke the reporter separately:

```bash
python3 scripts/delegation-report.py --source claude \
  --since <window_start_at> --json
python3 scripts/delegation-report.py --source codex \
  --since <window_start_at> --json
```

Missing transcript roots are per-source unavailable coverage, not whole-command
failure. Reporter malformed timestamps/boundaries propagate into coverage and
limitations. Both reporter sources are always partial with
`reason=upper_bound_unsupported` because `--since` cannot enforce L7's exclusive
end; record `reporter_completed_at` in the effectiveness record's `components`.
No transcript content enters inspect output.

### `priorities[]`

Sort by category order L11, then `evidence_count` descending, `newest_ts`
descending (`null` last), then `id`.

| Field | Type |
|---|---|
| `id` | `pri_` + 16 lowercase hex characters |
| `rank` | positive integer |
| `category` | L11 enum |
| `scope` | `shipyard_core|core_candidate` |
| `claim_kind` | `fact|derived|assessment` |
| `rule_id` | stable string |
| `title` | string |
| `project_ids` | sorted string array |
| `evidence_count` | positive integer |
| `newest_ts` | RFC3339 UTC string or `null` |
| `evidence_ids` | nonempty string array |
| `operands` | JSON object |
| `confidence_basis` | string |
| `limitations` | string array |

Rules:

- `confirmed_failure`: direct core-root evidence only—core doctor drift,
  core `job.end fail|partial`, failed core restart, or core critic
  spawn/delivery failure.
- `human_gate`: undecided proposal/owner decision whose project path is the core
  root.
- `recurring_failure`: at least two records sharing an L19 recurrence key
  across at least two project IDs; scope is always `core_candidate` and
  `claim_kind=assessment`.
- `evidenced_opportunity`: a core-root open proposal only when every referenced
  signal ID resolves exactly; otherwise it stays attention.
- `instrumentation_gap`: the same coverage/linkage gap blocks at least two
  projects or a historical benchmark; scope `shipyard_core` only for code/data
  under the core root, else `core_candidate`. Exact rule
  `budget_gate_scope_mismatch_v1` applies with `shipyard_core` scope when an
  applicable L31 design/shoulder consumer has a resolved
  `unscoped_event_root` whose canonical path is also resolved for more than one
  eligible project; its attributed and gate operands are the evidence, without
  requiring them to differ on this particular day. An unknown shoulder root
  never triggers this rule. Exact rule `budget_gate_root_mismatch_v1` applies
  with `shipyard_core` scope when an applicable build/release/medic/scribe
  consumer is `unset_sentinel` while L27 resolves emitted events to the core
  fallback.
- `hygiene`: matching duplicate manifests, stale result evidence under a
  source-specific contract, or deterministic low-severity core drift not above.

There is no composite score, no free-text clustering, and no automatic
promotion from “same failure in two projects” to “Shipyard defect.”

Priority IDs are:

```text
"pri_" + sha256(
  rule_id + NUL + scope + NUL
  + join(",", sort(unique(project_ids))) + NUL
  + join(",", sort(unique(evidence_ids)))
)[:16]
```

Use L18's UTF-8/NUL/lowercase-hexdigest rules. After deterministic sorting,
`rank` is assigned 1..N. Fixture tests permute
input records and require identical IDs/order.

### `summary`

```json
{
  "fleet_state": "fault_observed",
  "project_state_counts": {
    "fault_observed": 0,
    "degraded_observed": 0,
    "no_fault_observed": 0,
    "unknown": 0
  },
  "attention_count": 0,
  "effectiveness_state_counts": {
    "measured": 0,
    "partial": 0,
    "unmeasured": 0
  },
  "priority_count": 0,
  "top_priority_ids": []
}
```

Fleet state is the worst observed project state in order
`fault_observed > degraded_observed > unknown > no_fault_observed`; no projects
is exit 3 and emits no report. `top_priority_ids` is the first three priority
IDs after deterministic sorting.

## Context / Pointers

| Concern | Canonical source |
|---|---|
| Existing command parser, `status`, usage, dispatch | `skills/shipyard/shipyard.sh:18-104`, `:329-337` |
| Cross-harness skill contract | `skills/shipyard/SKILL.md:19-74` |
| Shared-skill install into two discovery roots | `install.sh:815-849`; `tests/install-skills.bats` |
| Generated service/timer manifest shape | `install.sh:643-735` |
| Doctor identity and finding contract | `install.sh:149-216`, `:373-378`; `tests/doctor.bats` |
| Config parser | `agents/lib/load-config.sh`; Python may use stdlib `tomllib` directly |
| Event/feedback/usage precedents | `agents/design/collectors.sh:43-221`; `tests/design.bats` |
| Daily budget consumer operands | `agents/{design,build,release,medic,scribe}/runner.sh` `tokens_used_today`; `agents/release/critic-watch.sh:18-21`, `:109-117` |
| Proposal/result path and decision filter | `agents/design/runner.sh:171-188`, `:228-241`, `:395-427` |
| Overseer applicability/result | `agents/overseer/runner.sh:1-31`, `:88-120`, `:170-190` |
| Delegation reporter CLI/schema | `scripts/delegation-report.py:620-695`; `tests/delegation-report.bats` |
| Event truth limitations | `agents/lib/log_event.sh:21-24`, `:73-108` |
| Public presentation claims | `docs/deck-editorial.json:43-103`, `:173-231`, `:300-423`, `:716-779`, `:884-905`; `docs/index.html:439-450` |
| Project gates/traps | `.agents/gates.md` |

The implementation helper filename is locked:
`skills/shipyard/inspect.py`. Focused tests live in
`tests/shipyard-inspect.bats`; immutable synthetic fixtures live under
`tests/fixtures/shipyard-inspect/`.

## Orchestration Protocol

The builder is the orchestrator. Delegate each phase exactly as written, keep
the orchestrator's context lean, and personally re-run every gate before every
commit. Delegation moves work, never verification. Every delegated brief below
inherits this clause verbatim:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

Every subagent returns **≤40 lines**: files changed; commands run plus exit
codes; RED/GREEN test names/counts; evidence values; blockers. Longer evidence
belongs in the Ledger. Before every commit, the orchestrator reads the diff and
re-runs the named focused and common gates.

## Measured Baseline — 2026-07-29

Polish verified the toolchain without writes, network calls, model calls, or
systemd mutations:

```text
Python 3.12.3 · Bash 5.2.21 · Bats 1.10.0 · jq 1.7
systemd 255 · Git 2.43.0 · ripgrep 15.2.0 · strace 6.8

bats tests/shipyard-status.bats tests/design.bats \
  tests/doctor.bats tests/delegation-report.bats
→ 69/69 passing, rc=0

bats tests/
→ 439/439 passing, rc=0, approximately 28s wall-clock

bash skills/shipyard/shipyard.sh status --project .
→ 6 timers listed, doctor clean, rc=0

./install.sh --doctor --project .
→ "shipyard crew install clean (checks a-j)", rc=0

syntax + Python compile → rc=0
leak-check → clean, rc=0
deck fresh / complete / render → all pass, rc=0
ticket lifecycle check → rc=0
strace execve smoke around /bin/true → 2 trace lines, rc=0
```

The current-user manifest probe found **31** matching canonical-role service
manifests resolving into this core root, representing **8** canonical project
paths; all 31 had paired timers. Seven project doctors were clean. One stale
temporary-checkout manifest was a real observed fault: doctor rc=1 with four
unit findings. This is the acceptance anchor—the new command must discover and
explain that degraded member rather than report an all-green fleet.

Read-only source timings on this fleet:

```text
doctor across 8 projects       ≈ 2.61s total
collector JSON, representative = 0.714–0.747s/project
delegation report, 2 cohorts   = 2.135s total
```

The delegation report also exposed real data-quality degradation: the 7-day
Claude cohort contained 2,897 malformed/missing timestamps, while the Codex
cohort contained three malformed task boundaries. Inspect must surface those
counts as partial coverage.

**Runtime acceptance:** on this same eight-project current-user fleet,
`inspect --json` must complete in **≤15.0 seconds** over three consecutive
runs (record each wall-clock value) without parallel mutation or a warm-cache
claim. This ceiling is derived from the measured ~10.7-second sequential source
budget with headroom. A miss is a blocker or an explicitly recorded
performance finding; do not drop sources to pass.

## Traps This Build Must Pin

- Work directly on `main` in this canonical checkout—no branch/worktree. Skill
  commits are fleet-live through symlinks at the next invocation.
- Before and after every skills commit:
  `ls -l "$HOME"/code/*/.claude/skills/ 2>/dev/null | grep -c worktrees`
  must print `0`; if not, stop and repair from the canonical checkout.
- `leak-check.sh` scans tracked files only. Before its first run, execute:
  `git add -N skills/shipyard/inspect.py tests/shipyard-inspect.bats
  tests/fixtures/shipyard-inspect/full-schema-v1.json`.
- Hard-wrapped prose assertions use a phrase contained on one source line.
  Existing-behavior guards must pass before edits.
- UTC formatting must not depend on Git/version locale. Parse RFC3339 and emit
  `YYYY-MM-DDTHH:MM:SSZ` explicitly.
- Systemd oneshot `inactive/dead/result=success` is normal. Never start, stop,
  enable, disable, reload, or reset a unit during inspect or its live proof.
- Do not call `design --check-config`: absent branch detection may refresh
  remote HEAD. Parse local TOML only.
- Do not reuse `jq fromjson?` in a way that hides invalid counts. Malformed and
  missing-timestamp records are observable coverage.
- No personal transcript, feedback, FYI, incident, or event body enters a
  fixture, Ledger, golden, or console output. Synthetic records only.
- Timers may append during live inspection. Capture the upper bound first,
  filter timestamps, and record non-atomic-snapshot limitation.
- `status` remains the no-argument default. A guard that only proves `inspect`
  works while breaking `status` is red.
- No post-merge/test command may be interactive, reach GitHub/network/model, or
  mutate systemd.
- No background process is needed. If a test accidentally starts one, it must
  clean it and prove no residue before commit.

## Common Per-Commit Gate

Every phase runs its focused commands plus this exact block before its commit:

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh \
  skills/shipyard/shipyard.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py \
  scripts/delegation-report.py skills/shipyard/inspect.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
bash scripts/ticket-lifecycle.sh --project . --check
git diff --check
git status --short
git log --oneline -3
```

Before the phase commit, `git status --short` may name only the phase-owned
paths plus this ticket. Add those paths explicitly, never `git add -A`. Commit
on `main`, run the zero-worktree-symlink check, then require a clean status.
Deck render is additionally mandatory in Phase 7, where deck source changes.

## Implementation Plan

### Phase 1 — CLI, manifest discovery, and immutable schema skeleton (3 pts)

**Goal:** add the explicit command, implement the exact v1 document skeleton,
and discover only matching current-user manifests without changing `status`.

**Delegation: subagent — bounded build brief.**

> Own only `skills/shipyard/inspect.py`,
> `skills/shipyard/shipyard.sh`, `tests/shipyard-inspect.bats`,
> `tests/fixtures/shipyard-inspect/`, and this ticket's Phase 1 Ledger fields.
> Implement the locked U1 answer, L3-L8, the top-level/meta/manifest coverage,
> evidence shell, fleet identity/roles, and exit handling. Use stdlib only.
> Create synthetic service manifests for two projects/multiple roles, a themed
> duplicate, unrelated service, arbitrary `CODE_ROOT` repo, second core root,
> missing `WorkingDirectory`, mismatched `WorkingDirectory` versus `--project`,
> and byte-matching spoof. Freeze the clock with
> `SHIPYARD_INSPECT_NOW`. First add the named RED contract test and run it
> against pre-change code; separately prove the existing status guard is green.
> Return ≤40 lines: files; RED/GREEN commands/exits/counts; exact discovered
> project/role totals; golden SHA-256; status guard; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**RED first:**

```bash
bats --filter \
  'inspect: discovers only matching current-root manifests and emits schema v1' \
  tests/shipyard-inspect.bats
bats tests/shipyard-status.bats
```

The inspect case must fail because the subcommand/helper do not exist. All six
status cases must pass before edits.

**Focused GREEN:**

```bash
bats --filter 'inspect: (discovers|dedupes|excludes|no fleet|malformed|default status|schema)' \
  tests/shipyard-inspect.bats
bats tests/shipyard-status.bats
python3 -m json.tool \
  tests/fixtures/shipyard-inspect/full-schema-v1.json >/dev/null
sha256sum tests/fixtures/shipyard-inspect/full-schema-v1.json
```

Named cases:

- `inspect: discovers only matching current-root manifests and emits schema v1`
- `inspect: dedupes canonical projects and roles`
- `inspect: excludes unrelated CODE_ROOT and other-root units`
- `inspect: excludes WorkingDirectory and project argument mismatch`
- `inspect: documents indistinguishable matching spoof`
- `inspect: no fleet exits 3 and emits no JSON`
- `inspect: malformed flags clock and days exit 2`
- `inspect: default status output is unchanged`
- `inspect: schema v1 golden covers every enum and nullable branch`

Before the first leak gate, `git add -N` all three new paths named in Traps.
Then run the Common Per-Commit Gate.

**Observable DoD:** fixed-clock fixture output matches the immutable schema
golden; exact project/role dedupe and exclusion counts pass; rc 0/2/3 are pinned;
the status pre-change guard stays byte-behavior compatible; no source adapter
beyond manifests has been falsely marked available.

### Phase 2 — config posture, systemd, and doctor truth (3 pts)

**Goal:** report configured safety posture, real timer/service state, and
install drift without treating normal inactive oneshots or unavailable
dependencies as failures.

**Delegation: subagent — bounded build brief.**

> Own `skills/shipyard/inspect.py`, `tests/shipyard-inspect.bats`, relevant
> synthetic fixtures, and Phase 2 Ledger fields. Add the exact read-only
> local `tomllib` config/safety adapter, `systemctl --user show` property
> adapters, and doctor subprocess adapter from the schema. Never call
> `--check-config`, trunk detection, or self-test. Use **two isolated PATH
> fixtures**: systemd-adapter cases use
> accepted project directories with no `.agents/config.toml` (doctor becomes
> unavailable without invocation) plus a strict systemctl stub that rejects
> every verb except `show`; doctor-adapter cases use the real fixture doctor plus the
> read-only systemctl stub pattern from `tests/doctor.bats` (allowing its
> `is-enabled`/inspection calls while rejecting mutation verbs). Never assert
> both call logs as one allowlist. Fixtures cover active timer+inactive
> successful oneshot, UTC timer normalization, malformed/local-time timer
> timestamp, disabled timer, failed
> service, missing timer, missing user bus, unknown property, clean doctor,
> structured drift, doctor missing `gh`, doctor unexpected rc, explicit branch
> and all configured safety gates, unset branch, runner defaults, and
> missing/malformed config with `autonomous=null`. First add
> named tests and demonstrate meaningful RED. Return ≤40 lines: files;
> RED/GREEN commands/exits/counts; safety/unit/doctor states and coverage reasons;
> rejected-mutation call count; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**RED and GREEN surface:**

```bash
bats --filter \
  'inspect: (configured safety|malformed config|inactive successful oneshot|timer timestamp normalization|disabled timer|failed service|missing user bus|preserves doctor|doctor dependency)' \
  tests/shipyard-inspect.bats
bash -n skills/shipyard/shipyard.sh
python3 -m py_compile skills/shipyard/inspect.py
```

Named cases:

- `inspect: inactive successful oneshot is no fault`
- `inspect: configured safety and five-key budget map use exact runner defaults`
- `inspect: malformed config is unavailable posture with unknown autonomy`
- `inspect: timer timestamp normalization is UTC and host independent`
- `inspect: disabled timer and failed service are direct faults`
- `inspect: missing user bus is unavailable not a fabricated fault`
- `inspect: preserves doctor rc and finding classes`
- `inspect: doctor dependency failure is coverage unavailable`
- `inspect: systemctl adapter rejects every mutation verb`

Use the real fixture installer/doctor pattern from `tests/doctor.bats`, with
PATH stubs for all dependencies and redirected `HOME`; do not touch the real
user manager. Run the Common Per-Commit Gate.

**Observable DoD:** exact systemd fields/nulls and UTC-normalized timer
timestamps match the golden; local-time/malformed timestamps become null with
malformed coverage; config posture represents every L25 field and never invokes
remote trunk/recovery proof; doctor clean,
drift, unavailable, and error are distinct; normal oneshot inactivity is not
red; the strict systemd-adapter log contains only `systemctl --user show`, while
the separate doctor log contains only its documented read-only inspection
verbs; neither contains a mutation; health state follows L17.

### Phase 3 — timestamped telemetry, data quality, and pressure (3 pts)

**Goal:** collect bounded events/FYI/usage/Caddy/incident state with explicit
invalid/out-of-window counts and no fail/abort conflation.

**Delegation: subagent — bounded build brief.**

> Own `skills/shipyard/inspect.py`, `tests/shipyard-inspect.bats`, telemetry
> fixtures, and Phase 3 Ledger fields. Implement L18-L21 file evidence,
> recurrence keys, exact rolling windows, events-directory precedence,
> event/job/incident/critique/pressure adapters, bounded FYI/usage, Caddy
> journal adapter, and exact current-incident file adapter. Resolve
> `QUARTET_EVENTS_DIR` **within each project** per L27: zero nonempty values use
> `$QUARTET_DIR/data/events`; one unique value wins; multiple unique values
> produce only that project's `events state=error reason=mixed`. Scan each
> unique root once; attribute by exact accepted service stem per L27 and keep
> unknown/ambiguous services out of project metrics with global counters. Two
> projects sharing one root and two projects with different internally
> consistent roots are both valid. Apply L31's current-UTC-day numerator to
> six distinct daily budget consumers, including separate release runner and
> shoulder critic records plus attributed-versus-gate operands and the
> non-design runner's unset `/nonexistent` gate. Journalctl
> stubs accept only the exact read command and reject mutation/nonlocal calls.
> Fixtures include valid, malformed, missing-ts, before-start, exactly-at-start,
> exactly-at-end, after-end, duplicate-identical, missing-incident-id,
> fail/partial/abort/skipped, token consumption by role, budget/open-cap
> deferrals, shoulder enabled/disabled/unknown, present-empty, missing,
> shoulder watcher roots explicitly configured/project-default/unknown,
> duplicate-key JSON, valid non-object, incompatible/fractional/negative token
> operands, sentinel present/absent, mixed-event-dir, a shared hub containing
> two projects plus an unknown service, query-bearing Caddy URI and an
> exactly-at-end journal record, and exact `medic-incidents-current.json`
> records with a secret-bearing summary that must be redacted. Show named RED first.
> Expose a pure `compute_gate_operand(path, consumer, svc)` helper; Bats imports
> it through Python for present/absent sentinel fixtures under
> `$BATS_TEST_TMPDIR`. Production resolution remains literal `/nonexistent`;
> never create that host path or add a production environment override.
> Return ≤40 lines: files; RED/GREEN
> commands/exits/counts; coverage totals; exact status/incident/pressure values;
> mutation/network/model call counts; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**Focused surface:**

```bash
bats --filter \
  'inspect: (rolling window|canonical evidence|exact event routing|duplicate keys|malformed coverage|fail abort partial|dedupes incidents|event attribution|event directory|budget consumers|gate operand|unset non-design|shoulder gate root|under-cap|budget pressure|present empty|Caddy)' \
  tests/shipyard-inspect.bats
python3 -m py_compile skills/shipyard/inspect.py
```

Named cases:

- `inspect: rolling window is start-inclusive and end-exclusive`
- `inspect: canonical evidence ids pin JSONL lines and structured pointers`
- `inspect: exact event routing emits at most one evidence row per line`
- `inspect: malformed missing-ts and out-of-window records remain coverage`
- `inspect: distinguishes fail abort partial and unknown job statuses`
- `inspect: duration nearest-rank percentiles pin odd and even samples`
- `inspect: dedupes incidents and rejects missing incident ids`
- `inspect: event directory precedence rejects mixed roots`
- `inspect: shared event hub attributes exact service stems without contamination`
- `inspect: unknown event service is global unattributed coverage only`
- `inspect: per-project event roots may differ without conflict`
- `inspect: same-day budget consumers separate runner critic and gate scope`
- `inspect: absent unset non-design sentinel is zero not core-fallback use`
- `inspect: gate operand reproduces jq pipeline and shell normalization`
- `inspect: duplicate keys affect gate compatibility but never evidence`
- `inspect: shoulder gate root is proven from watcher manifest or unknown`
- `inspect: under-cap use is healthy while exhaustion and deferral degrade`
- `inspect: budget and open-cap deferrals are not job failures`
- `inspect: present empty and unavailable sources are distinct`
- `inspect: Caddy is end-exclusive strips query and never networks`
- `inspect: current incident state uses configured result file and redacts summary`

Hash every synthetic input before/after the focused command and assert identical
hash sets. Run the Common Per-Commit Gate.

**Observable DoD:** the fixed-clock golden has exact valid/invalid/out-of-window
counts; duplicate lines have distinct evidence IDs and one recurrence key;
shared hubs cannot contaminate projects; distinct daily consumer ratios and
gate operands obey L31; `abort`
is not `fail`; current incident state and bounded telemetry obey L20; no raw
body is emitted.

### Phase 4 — proposals, decisions, attention, and Overseer assessment (3 pts)

**Goal:** show what needs the operator while respecting configured result paths,
decision suppression, unverifiable signal IDs, and Overseer applicability.

**Delegation: subagent — bounded build brief.**

> Own `skills/shipyard/inspect.py`, `tests/shipyard-inspect.bats`, state
> fixtures, and Phase 4 Ledger fields. Implement L22-L23, L30, plus
> `attention[]`.
> Parse local TOML with stdlib `tomllib`; honor non-`tmp` result dir,
> plain/spacetime/custom design displays, exact result filename
> `<project_name>-<display>-result.json`, and
> `<project>/data/decisions.jsonl` records under exact L30. Fixtures contain an
> open resolvable proposal, open bogus-signal proposal, approve-decided
> proposal, deny-decided proposal, invalid `id`-instead-of-`proposal_id`,
> unknown decision value, invalid timestamp, conflicting valid decisions,
> persisted missing approval action, explicit observed fault,
> coverage gap, configured max-open cap/current remaining capacity,
> autonomous result, autonomous missing result, non-autonomous repo, and
> config-unknown repo. Never invoke Overseer or a runner. Show named RED first.
> Return ≤40 lines: files; RED/GREEN commands/exits/counts; surviving/suppressed
> proposal IDs; applicability states; invocation log; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**Focused surface:**

```bash
bats --filter \
  'inspect: (configured result dir|suppresses exact|conflicting valid decisions|bogus signal|approval action|Overseer|attention)' \
  tests/shipyard-inspect.bats
python3 -m py_compile skills/shipyard/inspect.py
```

Named cases:

- `inspect: configured result dir and themed design display locate proposals`
- `inspect: suppresses exact approve deny decisions and counts malformed rows`
- `inspect: conflicting valid decisions suppress with partial mixed coverage`
- `inspect: bogus signal proposal stays assessment not evidenced opportunity`
- `inspect: missing persisted approval action is explicit`
- `inspect: undecided proposals populate current open-cap pressure`
- `inspect: Overseer distinguishes applicable absent and not applicable`
- `inspect: unknown autonomy makes Overseer unavailable not inapplicable`
- `inspect: attention contains faults drift gates and coverage gaps`
- `inspect: never invokes Overseer or runner check-config`

Run the Common Per-Commit Gate.

**Observable DoD:** exact approve/deny and conflicting-valid proposal IDs are
suppressed; open proposals targeted only by malformed/unknown decision rows
remain; bogus signal and missing approval action limitations are exact;
non-autonomous Overseer is not an instrumentation gap while unknown autonomy is
unavailable; every attention ID
refers to evidence; no runner/model was invoked.

### Phase 5 — honest effectiveness benchmarks and delegation cohorts (3 pts)

**Goal:** report what Shipyard's outcomes can and cannot prove, including
separate Claude/Codex delegation data and explicit Hermes absence.

**Delegation: subagent — bounded build brief.**

> Own `skills/shipyard/inspect.py`, `tests/shipyard-inspect.bats`, synthetic
> delegation/lineage fixtures, and Phase 5 Ledger fields. Implement the exact
> eight `effectiveness[]` records and L24. Invoke delegation-report separately
> for Claude and Codex using synthetic `CLAUDE_PROJECTS_DIR`,
> `CODEX_SESSIONS_DIR`, and fixture `--tickets-dir`; never read the real store
> in tests. One source root is absent, one has malformed timestamps/boundaries,
> one record is at/after `inspection_started_at`, and Hermes is unsupported.
> Fixtures cover measured delegation plus partial/unmeasured benchmarks;
> disconnected proposal/decision/build evidence must keep `value:null`.
> Reporter coverage must disclose its unsupported exclusive upper bound. Show
> named RED first. Return ≤40 lines: files; RED/GREEN
> commands/exits/counts; all eight state/value pairs; malformed propagation;
> transcript-content grep result; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**Focused surface:**

```bash
bats --filter \
  'inspect: (historical benchmarks|missing linkage|delegation cohorts|unsupported Hermes|reporter malformed)' \
  tests/shipyard-inspect.bats
python3 -m py_compile skills/shipyard/inspect.py
```

Named cases:

- `inspect: historical benchmark windows and targets are labelled`
- `inspect: missing linkage is partial with null value`
- `inspect: benchmark component facts never claim measured in v1`
- `inspect: successful delegation cohort is measured with partial window coverage`
- `inspect: Claude and Codex delegation cohorts are independent`
- `inspect: missing reporter root degrades only that cohort`
- `inspect: reporter malformed counts propagate to coverage`
- `inspect: reporter upper bound limitation covers at-and-after start records`
- `inspect: unsupported Hermes is unmeasured not zero`
- `inspect: no transcript content enters output`

Run the Common Per-Commit Gate.

**Observable DoD:** all eight records match schema order; records 1–5 never
claim measured; no disconnected facts earn credit; reporter failures are
source-local; malformed and upper-bound limitations appear in coverage;
transcript fixture content is absent from output.

### Phase 6 — explainable priorities and human rendering (3 pts)

**Goal:** turn facts into deterministic, bounded recommendations and render the
operator view from the JSON document only.

**Delegation: subagent — bounded build brief.**

> Own `skills/shipyard/inspect.py`, `tests/shipyard-inspect.bats`, priority/
> rendering goldens, and Phase 6 Ledger fields. Implement all six categories,
> L11-L14/L18-L19 ordering and scope rules, summary rollup, and one human
> renderer whose only input is the completed report object. Human format:
> header/window; `FLEET`; `ATTENTION`; `EFFECTIVENESS`; `NEXT SHIPYARD PR`;
> `COVERAGE`. Each `FLEET` line includes project ID/state, role count, doctor
> state, current-day budget/open-cap pressure, and compact configured-gate
> posture (`merge`, `no-ci`, `verify`, `branch`); null/unavailable is explicit.
> Every attention/priority line includes its stable ID; each
> priority prints category/scope, title, `rule_id`, and one “why” line naming
> evidence count plus limitations. Empty sections print `none`; unavailable is
> never blank. Fixtures cover all categories, equal-count recency/ID ties,
> direct core fault, two-project identical provider failure, project-only app
> fault, unresolved proposal signal, benchmark gap, proven multi-project
> design/shoulder budget root, unset non-design gate root, unknown shoulder
> root, and no priorities. Show
> named RED first. Return ≤40 lines: files; RED/GREEN commands/exits/counts;
> ordered IDs; human↔JSON ID comparison; stdout/stderr cleanliness; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**Focused surface:**

```bash
bats --filter \
  'inspect: (priority categories|priority tie break|project local|core candidate|budget gate|unset non-design|unknown shoulder root|human priority ids|human fleet lines|empty sections|JSON stdout)' \
  tests/shipyard-inspect.bats
python3 -m py_compile skills/shipyard/inspect.py
```

Named cases:

- `inspect: priorities obey category evidence recency id order`
- `inspect: attention and priority ids survive input reordering`
- `inspect: direct core failure is shipyard_core`
- `inspect: exact cross-project recurrence is core_candidate assessment`
- `inspect: project-local failure stays attention`
- `inspect: unresolved proposal signal cannot become opportunity`
- `inspect: benchmark gap becomes explainable instrumentation priority`
- `inspect: shared-root budget gate becomes Shipyard instrumentation priority`
- `inspect: unset non-design gate becomes Shipyard instrumentation priority`
- `inspect: unknown shoulder root cannot become shared-root priority`
- `inspect: human attention and priority ids map exactly to JSON`
- `inspect: human fleet lines expose pressure and configured safety posture`
- `inspect: empty and unavailable sections render explicitly`
- `inspect: JSON stdout contains JSON only and diagnostics use stderr`

Run the Common Per-Commit Gate.

**Observable DoD:** exact ordered IDs match fixture golden; no opaque score or
free-text grouping exists; project/provider examples are not called core facts;
human IDs equal JSON IDs; all sections render truthfully from one object.

### Phase 7 — shared-skill/docs/deck contract, real-fleet proof, graduation (2 pts)

**Goal:** make inspect discoverable through the two shared-skill roots for all
three harnesses, align canonical public claims, prove the real fleet, and
graduate only after every gate.

**Delegation: subagent — bounded docs/contract audit brief.**

> Own `skills/shipyard/SKILL.md`, `README.md`,
> `docs/deck-editorial.json`, generated `docs/shipyard-data.json`,
> `tests/shipyard-inspect.bats`, relevant install-skill tests, and Phase 7
> Ledger fields. Update the existing command/console prose; do not add a
> parallel explainer. State current-user/core-root scope, read-only behavior,
> human/JSON forms, non-certifying health, and recommendation limitations.
> Correct the README budget claim to distinguish the six L31 consumers and
> disclose any proven current multi-project design/shoulder gate scope without
> claiming an unknown shoulder root.
> Update the skill frontmatter triggers/subcommand count, regenerate deck data,
> and prove `.agents/skills/shipyard` (Codex) plus
> `.claude/skills/shipyard` (Claude/Hermes) resolve to the same core. Use a
> source-line-safe pre-change guard and show the new contract RED first. Return
> ≤40 lines: files; RED/GREEN commands/exits/counts; generated diff summary;
> two-root realpaths; docs claims checked; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**Focused docs/discovery gate:**

```bash
bats tests/shipyard-inspect.bats tests/shipyard-status.bats \
  tests/install-skills.bats tests/harness-install.bats
python3 scripts/gen-deck-data.py
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
```

Render exit 3 is the documented Playwright-unavailable skip; any other nonzero
exit blocks.

**Orchestrator's real read-only proof:**

```bash
git status --short
./install.sh --doctor --project .
proof_dir="$(mktemp -d)"
trap 'rm -rf "$proof_dir" /tmp/shipyard-inspect-v1.json' EXIT
export proof_dir

hash_inputs() {
  python3 - "$1" <<'PY'
import hashlib, json, os, pathlib, re, sys
out = pathlib.Path(sys.argv[1])
core = pathlib.Path.cwd().resolve()
unit_dir = pathlib.Path.home() / ".config/systemd/user"
paths = set()
for service in sorted(unit_dir.glob("*.service")):
    text = service.read_text(errors="replace")
    if f"ExecStart=/bin/bash {core}/agents/" not in text:
        continue
    paths.add(service.resolve())
    timer = service.with_suffix(".timer")
    if timer.exists():
        paths.add(timer.resolve())
    match = re.search(r"^WorkingDirectory=(.+)$", text, re.M)
    if match:
        cfg = pathlib.Path(match.group(1)) / ".agents/config.toml"
        if cfg.exists():
            paths.add(cfg.resolve())
payload = {
    str(path): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(paths)
}
out.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY
}

hash_inputs "$proof_dir/before.json"
strace -f -e trace=execve -o "$proof_dir/exec.log" \
  bash skills/shipyard/shipyard.sh inspect --json \
  > /tmp/shipyard-inspect-v1.json
hash_inputs "$proof_dir/after.json"
cmp "$proof_dir/before.json" "$proof_dir/after.json"

! rg -n 'execve\\(.*(claude|codex|hermes|curl|wget|notify\\.sh|gh")' \
  "$proof_dir/exec.log"
! rg -n 'systemctl.*(start|stop|restart|enable|disable|daemon-reload|reset-failed)' \
  "$proof_dir/exec.log"

bash skills/shipyard/shipyard.sh inspect
jq -e '
  .schema_version == 1
  and .meta.project_count == (.fleet | length)
  and (
    ([.attention[]?.evidence_ids[]?,
      .effectiveness[]?.evidence_ids[]?,
      .priorities[]?.evidence_ids[]?,
      .fleet[]?.state_reason_ids[]?] | unique) as $refs
    | ([.evidence[].id] | unique) as $ids
    | (($refs - $ids) | length) == 0
  )
' /tmp/shipyard-inspect-v1.json >/dev/null
for i in 1 2 3; do
  /usr/bin/time -f "run=$i seconds=%e" \
    bash skills/shipyard/shipyard.sh inspect --json >/dev/null
done
systemctl --user list-timers 'shipyard-*' --no-pager
git status --short
```

The JSON report must discover the measured fleet baseline (or explain dated
drift), surface any stale matching manifest/doctor finding, propagate reporter
malformed counts, and complete each timed run in ≤15.0 seconds. Compare every
human attention/priority ID with `/tmp/shipyard-inspect-v1.json`. `/tmp` output
is local-only and removed before hand-off.

The exact hash/`strace` commands above are the live read-only gate. Hermetic
fixture tests provide full tree equality. Live event/result files are not
byte-equality gates because timers may append concurrently. The exec trace must
contain no harness/model/network/notification process and no mutating systemctl
verb; unexpected executables are recorded and audited before proceeding.

Run the Common Per-Commit Gate, with `node scripts/check-deck-render.mjs`
added. Set every roll-up DoD box honestly and finish Ledger evidence.

**Graduation:**

```bash
# First change the opening Status to:
# Complete — built and verified <UTC date>
bash scripts/ticket-lifecycle.sh --project . --graduate \
  docs/tickets/pending/shipyard-fleet-inspect-cli.md
bash scripts/ticket-lifecycle.sh --project . --check
test -f docs/tickets/complete/shipyard-fleet-inspect-cli.md
test ! -e docs/tickets/pending/shipyard-fleet-inspect-cli.md
git diff --check -- docs/tickets/complete/shipyard-fleet-inspect-cli.md
git status --short
```

Commit only the pending→complete move and final Ledger. Then obey U2 exactly:
push `main` (and verify the documented deck cascade) only if authorized;
otherwise stop with clean local commits and report that publication is pending.

**Observable DoD:** two discovery roots/three harnesses share one implementation;
docs/deck match real behavior; real JSON/human reports are evidence-linked and
within the measured ceiling; input hashes/unit state are unchanged; all gates
are green; ticket exists only under `complete/`.

## Testing Strategy

- `tests/shipyard-inspect.bats` is the focused behavior contract. Every named
  phase case is added before its implementation and recorded meaningfully RED;
  existing-behavior guards are shown green pre-change.
- Use `quartet_setup`, redirected `HOME`, `make_fixture_project`, and
  `make_stub`/`make_stub_script` from `tests/helpers.bash`; no test reaches the
  real systemd user instance, GitHub, network, model, event store, or transcript
  store.
- Hand-author synthetic manifests, systemd property output, JSONL, decisions,
  proposals, usage/FYI, Overseer results, and Claude/Codex transcript fixtures.
  Never copy, sanitize, or quote private live content into tracked fixtures.
- The full schema golden covers every enum/null branch. Focused cases assert
  exact evidence IDs, coverage counters, sort order, unavailable-vs-empty,
  source-specific windows, exit 0/2/3, and before/after input hashes.
- Subprocess stubs default-deny: only the documented read-only systemctl,
  journalctl, doctor, and reporter invocations succeed; every mutation,
  network, model, runner, or notification command fails the test.
- Preserve existing `tests/shipyard-status.bats`; no-argument remains `status`.
- The Common Per-Commit Gate is mandatory for each phase. Phase 7 additionally
  proves two shared-skill roots/three harness consumers, renders the deck,
  runs the actual command on the live current-user fleet, and performs
  deterministic lifecycle graduation.
- A case that cannot fail when its named defect is reintroduced is a finding,
  not a test; record and repair it before commit.

## Roll-up Definition of Done

- [x] U1 and U2 are answered and locked into Decisions/Ledger before Phase 1.
- [x] `shipyard inspect` discovers every and only matching eligible manifest
      for the current user's systemd instance and this resolved core root,
      deduped by canonical path+role; skills-only, arbitrary `CODE_ROOT`,
      other-user, other-core-root, and indistinguishable-spoof limitations are
      explicit.
- [x] The existing no-argument/`status`, `add-specialist`, and `learn` behavior
      and exit semantics are unchanged.
- [x] Default output is a concise whole-fleet operator report; `--json` emits
      the stable `schema_version:1` source document; human output is rendered
      only from that document.
- [x] `--days N` and the injected fixture clock implement the exact L7 rolling
      interval and reject non-positive/non-integer/invalid values with exit 2.
- [x] No eligible fleet exits 3; unhealthy/degraded fleet data still produces a
      report and exits 0.
- [x] Fleet/project state uses only
      `fault_observed|degraded_observed|no_fault_observed|unknown`; normal
      inactive oneshots are not faults and absent events never certify health.
- [x] Coverage reports valid/invalid/out-of-window counts and source-specific
      applicability/freshness; present-empty is distinguishable from missing;
      shared event roots are scanned once and exact service attribution prevents
      project contamination while preserving global unknown/ambiguous counts.
- [x] Health evidence includes roles/unit state, doctor drift/unavailability,
      exact job statuses/reasons, deduped incidents, critic failures/findings,
      distinct same-UTC-day runner/shoulder budget consumers with exact
      attributed-versus-gate operands, current open-cap pressure, and never
      merges abort into failure; incident summaries and query values never enter
      output.
- [x] Configured safety posture reports the exact locked gate/default/trunk
      fields; it never substitutes remote/recovery proof it did not run.
- [x] Attention includes open-undecided proposals and direct operator-relevant
      failures/gaps, with configured result paths/themes honored, decided
      proposals suppressed only by exact valid L30 records, malformed/conflicting
      decision coverage explicit, unresolved signal IDs limited, missing
      approval action explicit, and no action taken.
- [x] Overseer is applicable only to observed-autonomous projects, explicitly
      unknown when config cannot establish autonomy, and never invoked.
- [x] Every historical presentation benchmark is labelled with its own window
      and reported `measured|partial|unmeasured`; missing linkage has
      `value:null`, never fractional credit or zero.
- [x] Claude/Codex delegation cohorts are independent and propagate malformed
      counts; missing roots are source-local; Hermes is explicitly unsupported.
- [x] Priorities use the six locked categories and deterministic tie-breakers;
      every candidate exposes rule, evidence, claim kind, confidence basis,
      limitations, and scope; no opaque score or free-text semantic clustering
      exists.
- [x] Project-local app problems remain attention; direct core evidence may be
      `shipyard_core`; exact cross-project recurrence is only a
      `core_candidate` assessment.
- [x] Every attention/effectiveness/priority evidence ID resolves to the
      versioned evidence table; exact JSONL-line/structured-pointer canonical
      identities and fixture output match the full schema golden.
- [x] The command performs no writes, notifications, approvals, ticket
      creation, systemd state changes, model calls, or network calls, proven by
      default-deny stubs, input hashes, and live invoked-command audit.
- [x] Claude, Codex, and Hermes reach the same installed skill/core; no
      harness-specific inspect implementation or global binary is added.
- [x] `skills/shipyard/SKILL.md`, `README.md`, and the existing deck node
      document the shipped behavior; generated deck data is current.
- [x] Focused RED-first cases and the full `bats tests/`, syntax/compile,
      leak-check, deck freshness/completeness, and optional render gates pass;
      real-fleet human/JSON output is structurally and semantically compared.
- [x] Three real `inspect --json` runs each finish in ≤15.0 seconds without
      omitting a source; any baseline fleet drift is explained, not hidden.
- [x] Every phase's Ledger entry records its actual `builder:` line and gate
      evidence; the working tree is clean after each committed phase.
- [x] Status is Complete and the ticket exists only under
      `docs/tickets/complete/`; push/publication follows the recorded U2 answer.

## Boundaries

### Always

- Operate read-only and locally; report evidence and limitations before advice.
- Use matching current-user/current-core-root manifests as the bounded fleet
  authority and canonicalize every accepted runner/project path.
- Produce human and JSON views from one versioned document.
- Keep facts, deterministic derivations, and persisted assessments visibly
  distinct.
- Count malformed/out-of-window records and use source-specific windows.
- Preserve existing command behavior and the 0/2/3 exit contract.
- Use hermetic synthetic fixtures and the project's red-first test convention.

### Ask first

- Any event/result schema change to make an unmeasured effectiveness outcome
  measurable.
- Any new network/hub/ICE API integration, model-assisted semantic grouping, or
  automatic ticket/proposal creation.
- Any change that writes global configuration, installs a PATH binary, or
  alters systemd unit generation.
- Any outward-facing publication other than the explicit U2 answer.

### Never

- Start, stop, restart, enable, disable, or reload a unit; approve/deny a
  proposal; edit a project; append an event/decision; notify the owner; or spend
  model tokens.
- Scan arbitrary repositories under `CODE_ROOT` and call them installed.
- Represent missing/unlinked data as zero, success, measured effectiveness, or
  certified health.
- Use free-text semantic clustering, an opaque composite score, or a model
  judgment to rank priorities.
- Add a daemon, dashboard, database, package dependency, top-level module
  boundary, separate harness implementation, or second global CLI.

## Dependencies

- No new external dependency. Required local tools are already Shipyard
  requirements; missing doctor/reporter dependencies degrade through coverage.
- The command may consume but does not require existing event streams, result
  files, decisions, Overseer results, or transcript reports; absent inputs
  degrade explicitly through `coverage`.
- No ticket blocks this work. The other pending ticket's outcome phase is
  time-deferred and does not touch this command surface.

## Risks & Mitigations

- **A fleet scan accidentally includes unrelated/stale units.** Mitigation:
  matching current-root runner check, canonical project+role dedupe, explicit
  spoof limitation, and other-root/duplicate-theme fixtures.
- **“Unhealthy” becomes an unauditable opinion.** Mitigation: health facts keep
  exact status/reason/source records; the state enum says “observed,”
  assessments are labelled, and findings do not overload process exit.
- **A missing source looks like a clean fleet.** Mitigation: explicit coverage
  counters/reasons; unavailable and malformed never default to zero.
- **The priority list sends work to the wrong repo.** Mitigation: direct-core or
  advisory cross-project scope; project-local candidates remain attention; each
  recommendation explains its rule/evidence/limitations.
- **Human and agent output drift.** Mitigation: one JSON document, one human
  renderer, stable schema version, and parity tests.
- **Inspecting has side effects through reused tools.** Mitigation: invoke only
  documented read-only surfaces, never refresh Overseer, stub every subprocess,
  and snapshot fixture/real state before and after.
- **A large transcript/event history makes the command slow.** Mitigation:
  rolling 7-day default, bounded file selection, per-source counts, no model/
  network calls, and a measured 15-second real-fleet ceiling.
- **Concurrent timers make the snapshot internally non-atomic.** Mitigation:
  capture the upper bound first, exclude later timestamps, hash stable live
  inputs only, and report the limitation.
- **Config gating makes the whole-fleet command awkward or silently violates a
  house rule.** Mitigation: U1 blocks execution and is recorded before code.
- **Docs changes publish without authority.** Mitigation: U2 blocks execution;
  final push behavior follows its exact answer.
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
- Adding an ownership/version marker to systemd manifests; v1 documents the
  matching-spoof limitation.
- Adding Hermes transcript parsing to `delegation-report.py`.

## Ledger

For every phase append:

- plan;
- `builder: subagent (<N> agents)` or the exact exception-listed inline reason;
- RED command/failing assertion/exit and pre-change guard result;
- focused GREEN command/count/exit;
- Common Per-Commit Gate counts/exits;
- exact observable evidence and deviations;
- commit hash.

Before Phase 1, record U1 and U2 verbatim. Phase 7 records all three runtime
measurements, live fleet summary counts, input-hash proof, deck gate, lifecycle
move, and push/publication result or explicit local-only stop.

---

### Execution preflight — 2026-07-29T19:05:27Z

- Owner answers, verbatim: U1 “no config”; U2 “push”.
- `builder: inline (decision recording is a change under 30 lines; baseline
  gates are orchestrator-owned verification)`.
- Clean canonical `main`; no skill symlink resolves through a worktree.
- Live baseline: `install.sh --doctor --project .` rc=0; `shipyard status`
  lists six timers and a clean doctor; `systemctl --user list-timers
  'shipyard-*'` lists all six expected next fires.
- Green baseline: `bats tests/` 439/439; syntax/pycompile rc=0; leak-check
  clean; deck fresh/complete/render pass; lifecycle rc=0.
- `$QUARTET_NOTIFY_CMD` and `$QUARTET_EVENTS_DIR` are unset in this interactive
  shell; completion notification cannot be fired through the configured path
  from this process, so final proof will record that limitation.

`polish-ticket` complete. Auto-gate is **PROCEEDING** through:

```text
execute-ticket docs/tickets/pending/shipyard-fleet-inspect-cli.md
```

### Phase 1 Ledger — CLI, discovery, schema skeleton

- Plan: add the explicit no-config `inspect` dispatch; implement exact
  current-user/current-core manifest discovery, clock/window validation, v1
  document skeleton, human/JSON entry points, and rc 0/2/3 while preserving
  byte-behavior of default/status.
- `builder: subagent (1 agent)`.
- RED: the named discovery contract failed at its required `status == 0`
  assertion (1/1 failed, rc 1) against the pre-change command; the independent
  pre-edit status guard remained 6/6 green, rc 0.
- Focused GREEN: all nine inspect cases passed, rc 0; the status guard stayed
  6/6 green; the related status/add-specialist/learn compatibility sweep was
  34/34 green; JSON validation, shell syntax, and Python compilation were rc 0.
- Common Per-Commit Gate: full Bats 448/448, rc 0; syntax/compile rc 0;
  leak-check clean; deck freshness/completeness rc 0; lifecycle rc 0;
  `git diff --check` clean; worktree-symlink count 0.
- Observable evidence/deviations: synthetic discovery proved two projects and
  three unique roles; three same-project manifests deduped to two role units
  while retaining three manifest evidence records. Live JSON and human smoke
  both returned rc 0 with eight projects, 31 roles, and no non-manifest source
  falsely available. Exit classes 0/2/3 were exercised. Golden SHA-256 is
  `bfdacefad43f053d5fc0c90432a45f1bb1f94f076715a50542351f96e75c08f0`.
  The additive catalogue golden is compared to runtime object-key shapes
  rather than byte-for-byte because it intentionally enumerates later-phase
  enums/nullability. Orchestrator review additionally closed inspect-option
  leakage into other subcommands and exact explicit-option/positional rejection.
- Commit: `f93f80e` (`feat: add fleet inspect schema skeleton`).

### Phase 2 Ledger — config, systemd, doctor

- Plan: add local-only TOML posture, read-only `systemctl show`, UTC timer
  normalization, doctor state/finding adapters, and their evidence/coverage;
  preserve non-certifying health and default-deny every mutation path.
- `builder: subagent (1 agent)`.
- RED: the exact Phase 2 filter ran 8 named cases against the Phase 1
  skeleton; all 8 failed on their new state/schema assertions, rc=1.
- Focused GREEN: exact Phase 2 filter 8/8, rc=0; complete inspect suite 18/18,
  rc=0; related status+doctor suite 29/29, rc=0; shell syntax and Python
  compilation rc=0.
- Common Per-Commit Gate: full Bats 457/457, rc=0, including the post-repair
  orchestrator rerun; syntax/compile rc=0; leak-check clean; deck
  freshness/completeness rc=0; lifecycle rc=0; `git diff --check` clean.
- Observable evidence/deviations: configured posture produced the exact
  booleans, branch/unavailable-trunk states, sorted forbidden paths, and
  five-key budget map; malformed config produced `autonomous=null` and
  `config error/malformed`. UTC timer values normalized to `Z`; local-time and
  missing properties produced `systemd partial/malformed`; missing user bus
  produced `unavailable/systemd_unavailable`; disabled/missing timers and a
  failed service produced `fault_observed`, while inactive/dead/success did
  not. Doctor preserved clean rc=0, structured drift rc=1 and finding class,
  missing-dependency rc=2, and unexpected-rc `error/command_failed`.
  Strict systemd fixtures recorded exactly two read-only `show` calls with
  `LC_ALL=C`, `TZ=UTC`, and zero rejected/mutation calls; the separate doctor
  fixture log contained only `show`/`is-enabled`. No deviation.
- Repair audit RED: adversarial assertions added after independent review made
  5/8 focused cases fail, rc=1, exposing permissive bus-error classification,
  parser/counter gaps, max-open coercion gaps, and an over-broad doctor
  dependency match.
- Repair GREEN: exact Phase 2 filter 8/8, full inspect 18/18, and related
  status+doctor 29/29, all rc=0; Python compilation, shell syntax, and
  `git diff --check` were rc=0.
- Repair evidence: only exact standalone missing-user-bus diagnostics classify
  systemd unavailable; another rc=1 with empty output is
  `error/command_failed`. Unexpected, duplicate, malformed, and missing
  properties produced `total=14`, `valid=10`, `invalid=4`. Activating and
  enabled-runtime were non-fault, explicit failed was fault, and disabled
  timer, failed service, and missing timer each independently proved a direct
  fault. Doctor finding text containing `missing dependency: gh` remained
  drift while the exact standalone diagnostic classified coverage unavailable.
  Missing/invalid max-open values defaulted to 1, the ASCII string `"007"`
  normalized to 7, and the 300/301-second boundary was fresh/stale exactly.
  Independent re-audit passed all six repair findings. Live inspection was
  rc=0 in 2.67s, reported eight projects/31 roles and the observed Ice timer
  faults plus four `mg` doctor findings; all state/evidence references
  resolved, and unit/config hashes were unchanged before/after.
- Commit: `8c7e0cd` (`feat: inspect fleet posture and unit health`).

### Phase 3 Ledger — telemetry, attribution, pressure

- Plan: implement strict bounded telemetry and data-quality adapters, exact
  per-project event-root attribution, current incident state, Caddy/FYI/usage,
  six independent budget consumers and gate operands, without body/query leaks
  or fail/abort conflation.
- `builder: subagent (1 agent)`.
- RED: the literal ticket filter exited 1 with 0/11 passing; its regex selects
  only 11 of the 21 locked named cases. An expanded all-named filter exited 1
  with 0/21 passing, proving every new adapter assertion failed before the
  implementation.
- Focused GREEN: literal ticket filter 11/11, expanded all-named filter 21/21,
  full inspect 39/39, and related status+doctor 29/29, all rc=0. Python
  compilation and `git diff --check` were rc=0.
- Common Per-Commit Gate: orchestrator full Bats 478/478, rc=0;
  syntax/compile rc=0; leak-check clean; deck freshness/completeness rc=0;
  lifecycle rc=0; `git diff --check` clean. An earlier delegated broad run was
  intentionally interrupted after 212 passes; its rc=130 was SIGINT, not a
  product-test failure.
- Observable evidence/deviations: malformed event coverage was
  `total=4,valid=1,invalid=2,out_of_window=1`; current incident state was
  `total=3,valid=1,invalid=2`; Caddy was
  `total=2,valid=1,invalid=0,out_of_window=1`. Job status operands remained
  distinct (`fail=1,abort=1,partial=1,other=1`), and one incident deduped from
  08:00 through 10:00 with latest event `medic.incident.resolved`. Six
  attributed/gate token operands were exactly `[10,15,20,25,30,40]` against
  six 100-token caps; fraction 0.5 remained `no_fault_observed`, while 1.0
  became `degraded_observed`. Persistent telemetry fixture hashes and each
  rolling-test input hash set were byte-identical before/after. Strict stubs
  recorded zero systemd mutations/rejections, network/model calls, runner
  invocations, notifications, and rejected journal commands; Caddy used the
  one exact local read command. Bodies, incident summary, fragments, and query
  values were absent from output. The only deviation is the locked literal
  filter's incomplete title selection, covered by the expanded 21-case run.
- Performance repair: the orchestrator's real-fleet run was RED at 18.01s
  against the 15.0s ceiling. The new cache-isolation assertion failed 0/1
  before implementation, then passed 1/1. Canonical event-file paths now
  resolve once per physical file; strict gate-quality counts and jq-compatible
  gate operands use inspection-local caches whose keys retain exact path and,
  for exact-service consumers, service stem. Design/shoulder cache keys remain
  service-insensitive exactly like their locked filters. No persistent cache
  or jq-semantic replacement was introduced.
- Performance GREEN: expanded named cases 21/21 and full inspect 39/39, both
  rc=0; fixture hashes remained identical. Three real read-only
  `inspect --json` runs were 10.93s, 10.97s, and 10.77s, each rc=0 and each
  below 15.0s. No performance-repair deviation.
- Semantic repair RED/GREEN: the seven strengthened existing named cases
  failed 0/7 before repair and passed 7/7 after it; expanded named cases were
  21/21 and full inspect 39/39, all rc=0, with identical fixture hashes and
  clean compile/diff checks.
- Semantic repair evidence: unrouted design use, foreign shared-root use,
  divergent shoulder-root use, and a zero cap all degraded with nonempty
  state reasons resolving to existing config/manifest/watcher evidence.
  Gate invalid counts were `[2,2,2,2,2,2]` across the six consumers for a
  missing service plus an invalid routed numeric operand. Invalid persisted
  `http_status` produced null evidence operand and partial incident coverage.
  Build-role records carrying design deferrals remained routed evidence but
  did not increment design/open-cap pressure. Foreign-host Caddy records were
  filtered before counting, preserving `total=valid+invalid+out_of_window`,
  while malformed probe URL coverage was `partial/malformed` without a journal
  call. Post-repair live runs were 11.46s, 11.35s, and 11.32s, each rc=0 and
  below 15.0s. Independent re-audit passed all six findings. Orchestrator live
  proof was 11.14s, found no duplicate/unresolved evidence IDs, and every
  coverage row satisfied exact terminal-counter arithmetic. No
  semantic-repair deviation.
- Commit: `e503f05` (`feat: inspect fleet telemetry and pressure`).

### Phase 4 Ledger — operator attention and persisted state

- Plan: add exact proposal/result/decision/Overseer state adapters and build
  evidence-linked operator attention without invoking any runner, assessment,
  approval, or notification path.
- `builder: subagent (1 agent)`.
- RED: locked literal filter selected 6 cases and failed 0/6, rc=1; expanded
  named-case filter failed 0/10, rc=1, before implementation.
- Focused GREEN: locked literal filter passed 6/6, rc=0; expanded named-case
  filter passed 10/10, rc=0; `py_compile` rc=0.
- Common Per-Commit Gate: orchestrator full Bats passed 488/488, rc=0;
  remaining repository-wide checks are recorded immediately before commit.
- Observable evidence/deviations: configured plain/spacetime/custom result
  names resolved; valid approve/deny/conflicting IDs were suppressed while
  malformed-only targets survived; decision coverage was exact
  `5 total/2 valid/3 invalid` and conflict `partial/mixed`. Resolvable signal
  attention linked its FYI evidence, bogus signals stayed assessments, and all
  attention evidence resolved. Overseer states covered present, applicable
  absent, not applicable, and unknown autonomy without invocation. Dedicated
  immutable-input digest was identical before/after
  `de5f264e83fe20c1b850edaa4fb4cb95fe07bc0d43a84108abd1b2735a38b81d`;
  rejected runner/Overseer/model/network/systemd-mutation/notify counts were
  all zero. No deviation.
- Repair evidence: adversarial extension selected 4 existing named cases;
  pre-repair 1/4 passed and 3/4 failed, rc=1 (strict Overseer rejection was
  already green). Post-repair selected cases passed 4/4, locked literal 6/6,
  expanded named 10/10, and the full inspector suite 49/49, all rc=0.
  Absolute, empty, and integer `result_dir` values now reproduce the runner's
  project-prefixed path; an unrepresentable structured value is explicit
  malformed coverage. Proposal duplicate/nonfinite/source-timestamp and exact
  enum/status/signal validation are pinned, as are malformed Overseer results
  and non-applicable proposal/decision coverage for projects without design.
  Repair immutable-input digest was identical before/after
  `b1df9f40cc3550adcee4d2a6d52b26f35b9b2aff2ef3f1e5021a94d8174588b9`;
  forbidden invocation counts remained zero. No repair deviation.
- Independent repair re-audit: PASS for runner-compatible `result_dir`
  resolution, strict persisted schemas, malformed Overseer handling, and
  suppression of proposal/decision noise on projects without design roles.
- Orchestrator live proof: rc=0 in 12.21s across 8 projects and 31 roles.
  All fleet states were `fault_observed` from persisted seven-day facts, the
  137 attention items partitioned exactly into 21 coverage gaps, 4 install
  drift items, 111 observed faults, and 1 open proposal, and every evidence
  reference resolved. Projects without design roles reported proposal and
  decision coverage as `not_applicable/unsupported`.
- Commit: `feat: inspect operator attention and decisions` (orchestrator;
  subagent was instructed not to commit).

### Phase 5 Ledger — effectiveness benchmarks and delegation cohorts

- Plan: add the eight locked effectiveness records, benchmark limitations, and
  source-local Claude/Codex/Hermes delegation coverage while preserving strict
  pre-inspection boundaries and excluding transcript content.
- Prior phase commit: `a7095bd`.
- `builder: subagent (1 agent)`.
- RED: ticket literal filter selected 3 cases and failed 0/3, rc=1; expanded
  named-case filter failed 0/10, rc=1, before implementation.
- Focused GREEN: ticket literal filter passed 3/3, rc=0; expanded named-case
  filter passed 10/10, rc=0; `py_compile` rc=0.
- Common Per-Commit Gate: orchestrator full Bats passed 498/498, rc=0;
  remaining repository-wide checks are recorded immediately before commit.
- Observable evidence/deviations: all eight effectiveness records were emitted
  in locked order. With no outcome components, records 1–5 were
  `unmeasured/null`; disconnected proposal/decision/job/usage/critique facts
  made them `partial/null`, never measured. Synthetic Claude and Codex
  reporters were independently `measured/1`; Hermes was
  `unmeasured/null` with unsupported coverage. Claude coverage was
  `partial/upper_bound_unsupported` with `2 total/1 valid/1 invalid`; Codex was
  the same state/reason with `4/1/3`, propagating one malformed record, one
  malformed boundary, and one malformed timestamp. Both cohorts named the
  unsupported exclusive upper bound and possible at/after-start inclusion.
  Missing-root coverage degraded only its source. Exact transcript-secret grep
  found zero matches (grep rc=1). No deviation.
- Completion-time repair evidence: strengthened the successful-cohort case with
  two controlled reporters and external return-boundary markers. Targeted RED
  failed 0/1, rc=1, because both completion fields reused
  `inspection_started_at`; targeted GREEN passed 1/1, rc=0, after capturing UTC
  separately immediately after each subprocess return. The behavioral gate
  proves `claude_return <= claude_completed < codex_return <= codex_completed`,
  both values are RFC3339 UTC, neither equals the injected inspection clock,
  and evidence `observed_at`, evidence operands, and effectiveness components
  agree per source. Expanded Phase 5 passed 10/10 and full inspector passed
  59/59, both rc=0; exclusive-upper-bound limitations were unchanged. No
  repair deviation.
- Performance repair evidence: the controlled overlap gate was RED at 0/1,
  rc=1, in 2.77s, then GREEN at 1/1, rc=0, in 1.59s. Its return markers prove
  `max(starts) < min(returns)` and each completion is at or after its own
  reporter return and differs from the inspection clock. Claude and Codex
  remain separate real reporter subprocesses, launched before fleet scanning
  and collected in deterministic Claude/Codex order; Hermes remains
  unsupported. Expanded Phase 5 passed 10/10 and the full inspector passed
  59/59, both rc=0. The real-fleet run improved from the orchestrator's 15.66s
  RED to 13.67s, rc=0, across eight projects/31 roles; all eight records and
  coverage semantics remained present (Claude 16, Codex 22, Hermes null). No
  performance-repair deviation.
- Decode-isolation repair evidence: a reporter emitting raw invalid UTF-8 made
  the strengthened source-isolation gate RED at 0/1, rc=1, in 0.54s by raising
  during subprocess text decoding and discarding the valid peer. The targeted
  gate then passed 1/1, rc=0, in 0.50s: Claude became
  `error/malformed` and `unmeasured/null` while Codex remained `measured/1`,
  and both retained their locked output positions. Only `UnicodeDecodeError`
  is converted to the existing malformed-output contract; `KeyboardInterrupt`
  and `SystemExit` are not caught. Expanded Phase 5 passed 10/10 in 2.70s and
  the full inspector passed 59/59 in 12.32s, all rc=0. No repair deviation.
- Independent final re-audit: PASS. Reporter subprocesses overlap each other
  and the fleet scan while staying independently attributed and deterministically
  ordered; completion timestamps follow each source's return; malformed UTF-8
  degrades only that source; no broad exception catch was added.
- Orchestrator live proof: three consecutive real read-only JSON runs were
  13.29s, 13.41s, and 13.59s, each rc=0 and below 15.0s. The live report
  contained all eight records in order: the five historical benchmarks were
  `partial/null`, Claude was `measured/16`, Codex was `measured/22`, and
  Hermes was `unmeasured/null`; every effectiveness evidence reference
  resolved.
- Commit: `feat: measure fleet effectiveness honestly` (orchestrator;
  subagent was instructed not to commit).

### Phase 6 Ledger — explainable priorities and human rendering

- Plan: derive the six locked priority categories with deterministic,
  evidence-bounded scope and render the complete operator console from the
  same JSON document.
- Prior phase commit: `f32fa44`.
- `builder: subagent (1 agent)`.
- RED: the ticket-literal filter selected four cases and passed 2/4, rc=1;
  the expanded exact named filter selected all 14 and passed 4/14, rc=1.
  Project-local attention, unresolved-signal non-promotion, unknown-shoulder
  non-promotion, and JSON stdout/stderr separation were the four pre-existing
  guards already green.
- Focused GREEN: the ticket-literal filter passed 4/4 and the expanded Phase 6
  filter passed 14/14, both rc=0; `py_compile` passed rc=0. The fixture emitted
  all six categories and 11 formula-verified IDs in locked
  category/evidence/recency/ID order. Reversing completed-document input arrays
  preserved priority order and IDs. Human output contained the same 14
  attention and 11 priority IDs as JSON.
- Observable evidence: direct core failure was a `shipyard_core` fact; exact
  two-project recurrence was only a `core_candidate` assessment; a unique app
  failure stayed attention; unresolved proposal evidence was not promoted.
  Historical linkage, shared design/shoulder roots, and unset non-design roots
  produced explainable instrumentation priorities with attributed/gate
  operands; unknown shoulder roots did not. Empty sections printed `none`, and
  fleet lines exposed IDs/state/roles/doctor/budget/open-cap plus configured
  merge/no-ci/verify/branch posture. JSON success wrote 24,850 stdout bytes and
  zero stderr; bad days wrote zero stdout and the diagnostic only to stderr.
- Common Per-Commit Gate: `bats tests/` passed 512/512, rc=0, in 89.15s;
  syntax/compile, leak-check, deck freshness, deck completeness, and
  `git diff --check` all passed rc=0.
- Runtime blocker: two real read-only JSON runs completed rc=0 in 15.24s and
  15.17s, exceeding the 15.0s ceiling. Re-deriving priorities 1,000 times took
  4.13s total (about 4ms/report), localizing the overage to the existing fleet
  scan rather than Phase 6 ranking. No runtime claim is marked green.
- Runtime repair evidence: live profiling measured 16.806s in document build
  and 10.829s cumulative in pressure aggregation; 28 unique gate operands
  repeated jq's identical `-R fromjson?` stage for shared physical files.
  The strengthened existing operand gate was RED at 0/1, rc=1, in 0.52s, then
  GREEN at 1/1, rc=0, in 0.52s. Its real subprocess counters prove two exact
  paths invoke the first jq stage twice total, while four selector/service
  keys invoke the second stage four times; uncached direct behavior remains
  five first/five second calls and both paths return `[4,4,6,0,11]`.
  Cached missing paths and a forced first-stage rc=23 each remain zero without
  invoking a second stage. The cache is inspection-local and stores only the
  first jq stage by canonical physical path; selectors, services, evidence,
  reporters, and the second jq stage are unchanged. Expanded Phase 6 passed
  14/14; the final inspector suite passed 73/73, rc=0, in 14.36s. The real
  JSON command passed rc=0 in 9.84s, closing the 15.0s blocker without a
  semantic/output deviation.
- Independent audit: PASS for all six category/scope rules, exact IDs/order,
  renderer parity, and explicit unavailable/empty output. A second audit
  passed exact jq semantics, physical-path and inspection-local cache scope,
  distinct selectors/services, missing-jq behavior, and unchanged evidence
  and invalid-record accounting.
- Orchestrator live proof: three consecutive JSON runs were 9.93s, 9.90s, and
  9.76s; human rendering was 10.06s, all rc=0 and below 15.0s. The live report
  emitted 18 priorities with no unresolved evidence references; all 137
  attention and 18 priority IDs appeared exactly once in human output and
  matched JSON. All five required human sections were present.
- Commit: `feat: rank fleet priorities and render operator view` (orchestrator;
  subagent was instructed not to commit).

### Phase 7 Ledger — shared contract, live proof, and graduation

- Plan: publish the existing shared skill/docs/deck contract, prove both
  discovery roots reach one core, execute the exact live read-only audit, and
  graduate the ticket only after every final gate.
- Prior phase commit: `3e54321`.
- `builder: subagent (1 agent)`.
- Docs/contract RED: the source-line-safe default-status guard passed 1/1,
  rc=0, and the new public-contract case failed 0/1, rc=1, at the absent
  `/shipyard inspect` trigger. The explicit two-root discovery case already
  passed 1/1 against the pre-change installer behavior.
- Docs/contract GREEN: the exact focused docs/discovery Bats set passed 90/90,
  rc=0; generator, deck freshness, deck completeness (8 installed skills),
  and deck render all passed rc=0. Generated data changed only the existing
  `/shipyard` glossary definition/example (two replacements).
- Public claims now bound inspect to matching current-user/current-core
  manifests, strictly read-only human/default and schema-v1 JSON views,
  non-certifying health, and deterministic recommendations limited by evidence
  and explicit coverage. The README names L31's six independently enforced
  daily consumers and promotes a multi-project design/shoulder gate scope only
  when current exact manifests prove a shared resolved root; unknown shoulder
  roots are never inferred.
- Discovery proof: `.agents/skills/shipyard` and
  `.claude/skills/shipyard` both resolved to the canonical
  `skills/shipyard` core; no separate harness implementation or global entry
  was added.
- Live install/proof: `install.sh --doctor --project .` passed checks a-j.
  The exact hash gate covered 77 matching unit/timer/config inputs; before and
  after manifests were byte-identical at
  `09204d2cc712a50892c13ed0910c1f1f90958d19a5f0fa49118f308f225e2397`.
  Human output carried all 155 attention/priority IDs exactly once and matched
  the JSON source document. Three final real JSON runs were 10.26s, 10.27s,
  and 10.48s, each rc=0 and below 15.0s.
- Invoked-command audit: the ticket's literal negative regexes produced known
  false positives for reporter arguments `--source claude|codex`, Codex-owned
  PATH shim directories, and read-only `systemctl is-enabled`; these matches
  were recorded rather than called green. An argument-aware audit of the same
  trace found zero successful Claude/Codex/Hermes, network, notification, or
  runner invocations and zero mutating systemctl verbs. The only successful
  systemctl verbs were 62 `show` and 59 `is-enabled`; the remaining executable
  set was the local shell/doctor/parser toolchain.
- Real fleet: 8 projects/31 roles, all currently `fault_observed`; 137
  attention items and 18 priorities. Effectiveness was 2 measured, 5 partial,
  and 1 unmeasured. Claude coverage was
  `partial/upper_bound_unsupported` with 16 valid/2335 invalid timestamp
  records; Codex was the same state with 23 valid/4 invalid; Hermes remained
  unavailable/unsupported. `mg` retained four real doctor findings. Six
  Shipyard timers were listed; no baseline drift was hidden.
- Local proof artifacts were removed after audit. Worktree-linked shared-skill
  count remained zero.
- Final Common Per-Commit Gate: orchestrator full Bats passed 514/514, rc=0;
  shell syntax and Python compilation passed; leak-check was clean; deck
  freshness/completeness and rendered-deck assertions passed; lifecycle and
  `git diff --check` passed.
- Graduation: all roll-up DoD items were checked from recorded evidence,
  opening status changed to `Complete — built and verified 2026-07-29 UTC`,
  and the lifecycle engine moved this ticket from `pending/` to `complete/`.
- Commit: `feat: publish fleet inspect operator contract` (orchestrator;
  subagent was instructed not to commit).

## Post-completion field finding — 2026-08-04

A later rolling reconstruction exercised this ticket's historical-benchmark
contract over `2026-07-30T16:09:30Z` through `2026-08-04T16:09:30Z`. It is not
the original trial window. The original Phase 12 trial ran over
`[2026-07-22T00:00:00Z, 2026-07-27T00:00:00Z)` and is owned by Ice's
`quartet-gaps-guardian-teeth` ticket.

The inspector behaved as specified during the reconstruction: all four floors
remained `partial` because component evidence exists but the required outcome
lineage does not. The operator dashboard therefore kept all four promises
unverified rather than promoting component counts into claims.

The original-window evidence was subsequently adjudicated as T1 PASS, T2 MISS
at two of three projects, T3 MISS because the only feature was built before its
later project-ledger approval and had no in-window Dispatch stamp, and T4 PASS:
two of four floors met. The delayed Work Mac bundle and PR #17 contain August
3–4 work, so they reconcile current history but do not receive July trial
credit.

The written misses, third-project real usage, prospective content-free lineage,
installer usage-source question, dispatch ledger, and presentation closeout are
tracked in `docs/tickets/pending/close-five-day-trial-findings.md`. This field
note records operational evidence and does not reopen or redefine this
completed ticket's acceptance.
