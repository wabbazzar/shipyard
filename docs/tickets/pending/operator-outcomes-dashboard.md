# Operator outcomes dashboard

- **Created:** 2026-08-01
- **Owner:** wabbazzar
- **Status:** ready
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 28 (six phases: 5 · 5 · 5 · 5 · 5 · 3)
- **Refs:** `dashboard/reader.py`, `dashboard/server.py`,
  `dashboard/static/index.html`, `dashboard/static/app.js`,
  `dashboard/static/styles.css`, `dashboard/tests/`,
  `skills/shipyard/inspect.py`, `skills/shipyard/shipyard.sh`,
  `agents/lib/log_event.sh`, `agents/lib/post-run.sh`,
  `agents/*/runner.sh`, `agents/release/critic-watch.sh`,
  `docs/shipyard-data.json`, `scripts/install-dashboard.sh`

## Summary

Turn the local Shipyard dashboard into an outcome-first promise audit backed by
one versioned, content-minimizing operator document. Shipyard owns telemetry,
lineage, KPI semantics, narrative order, and crew/skill topology; the existing
standalone dashboard used on macOS and Linux becomes a thin presentation of
that document, and a later Ice ticket consumes the same contract without
reimplementing it.

## Objective

For any supported 24-hour, 7-day, or 30-day window, `GET /api/operator` returns
one deterministic schema-versioned document that tells the human operator
which Shipyard promises are verified, violated, unverified, or not applicable;
what needs attention; how work moved through agents and skills; and which raw
evidence supports every claim. The installed standalone/macOS dashboard renders
that document as `Outcomes`, `Crew`, `Evidence`, and `Story` modes at
`1440×900` and `390×844`, while preserving unknowns and never deriving KPI
meaning in the browser.

## Problem / Background

The shipped dashboard is a trustworthy activity and health surface, but it
does not answer the larger operator question: “Is the fleet doing what
Shipyard says it does?”

- `EventReader.summarize()` in `dashboard/reader.py:434` derives lifecycle
  health and unresolved actionables.
- `_summary_payload()` in `dashboard/server.py:143` exposes counts, services,
  actionables, and parse errors, but no promise, outcome, topology, or narrative
  model.
- `build_document()` in `skills/shipyard/inspect.py:4207` already owns fleet,
  attention, effectiveness, evidence, limitations, and next-PR priorities.
  `_benchmark_effectiveness()` deliberately leaves values unset when feature,
  bug-fix, decision, or critique lineage is missing.
- The standalone client currently recomputes stale display state and derives
  actionable labels in `dashboard/static/app.js:54-94`; that is the beginning
  of adapter-owned semantics and must not spread.
- Shipyard inspection discovers only systemd `*.service` manifests in
  `skills/shipyard/inspect.py:190`, while the same dashboard is installed under
  macOS launchd by `scripts/install-dashboard.sh:339-374`. macOS must receive a
  scheduler adapter in core rather than a second dashboard implementation.
- The presentation already defines the declared crew/skill graph in
  `docs/shipyard-data.json`; the operator view should reuse that generated
  topology and overlay observed state instead of creating a competing diagram.

Current events expose enough activity to start, but not enough immutable
lineage to prove complete outcomes. There is no unique run ID; `episode` in
`agents/lib/post-run.sh:31-40` intentionally deduplicates equivalent outcomes
and therefore cannot identify one invocation. Build result files may contain
PR, branch, and item outcome fields, but `job.end` currently retains only
status, duration, exit, and tokens. Shoulder critique events retain counts and
token use but do not durably record successful delivery or a shared critique
identity.

## Verified Polishing Baseline — 2026-08-01

- `python3 -m unittest -v dashboard.tests.test_reader
  dashboard.tests.test_server` passed 40/40 in 0.473 seconds.
- `node dashboard/tests/browser.mjs --browser chromium --viewport 1440x900
  --screenshot-dir <mktemp-dir>` and the equivalent `390x844` command passed
  against Chrome 147. Both preserved selection/scroll after SSE, exposed no
  mutation controls or external request origins, rendered hostile text inert,
  and supplied a static reduced-motion equivalent. The screenshot directory is
  mandatory; omitting it exits nonzero and is not render evidence.
- `python3 dashboard/tests/benchmark_reader.py --rows 300000` returned 2,000
  bounded results in 1.359 seconds at 203.5 MiB peak RSS and left the source
  checksum unchanged.
- `bats tests/shipyard-inspect.bats tests/dashboard.bats
  tests/dashboard-install.bats tests/shoulder-mode.bats
  tests/codex-feedback-delivery.bats` passed 205/205.
- Python 3.12.3, Node 24.12.0, Bats 1.10.0, Git 2.43.0, authenticated `gh`,
  and executable Chrome are present.
- This Linux machine has no installed `shipyard-dashboard.service`, nothing
  listening on `127.0.0.1:8765`, and no launchd directory. Execution can prove
  the real installed systemd service, the shared static UI, and hermetic launchd
  fixtures; a native Mac launchd smoke is external confirmation, never a
  fabricated local gate.
- Visual critique of the baseline found a sound responsive evidence surface but
  an overlarge desktop masthead, repeated explanatory eyebrow labels, and no
  outcome/relationship hierarchy. The new composition must make the living map
  carry meaning and remove at least one redundant accessory before completion.

## Confirmed Product Decisions

| Decision | State | Rationale |
|---|---|---|
| The dashboard is an outcome-first promise audit | locked | Activity, token use, and lines changed explain outcomes; they are not outcomes themselves. |
| Shipyard owns meaning; Ice and macOS/Linux are thin adapters | locked | KPI formulas, priority, topology, and narrative must not drift by platform. |
| Update the existing standalone dashboard for macOS | locked | WorkMac shipped one platform-neutral browser UI plus launchd/systemd shells, not a separate Mac frontend. |
| New telemetry is content-minimizing | locked | Store only opaque identifiers, timestamps, enums, counters, token classes, hashes, and commit/PR references—never prompts, messages, diffs, filenames, critique prose, or result bodies. |
| Missing evidence stays visible | locked | Unknown must never be collapsed into healthy, successful, or zero. |
| Use the presentation’s tree as operational anatomy | locked | Declared topology remains stable; observed invocations, outcomes, and attention become overlays. |
| Narrative mode is deterministic | locked | Story copy and ordering come from the operator document; no dashboard model call or adapter interpretation. |
| Visual design uses restrained semantic color and gestalt | locked | Short aesthetic headings, intuitive grouping, and connected evidence replace explanatory prose. No new light theme is required. |
| Standalone navigation uses in-page modes | locked default | The current server exposes one static shell; modes avoid adding a routing framework solely for navigation. |

There are no open user-decision-class items.

## UI Direction

### Subject, audience, and job

- **Subject:** whether a fleet of agents is producing verified outcomes through
  the declared Shipyard loops.
- **Audience:** the human owner deciding where to intervene and where the next
  Shipyard PR should focus.
- **Job:** establish in under ten seconds what worked, what is uncertain, what
  needs the operator, and which evidence supports the conclusion.

**Design thesis:** A living map of the fleet: calm structure first, restrained
color for meaning, and visible evidence flowing from work to outcome.

### Information hierarchy

1. `Outcomes`: promise states, verified outcome chains, reliability, operator
   load, and bounded efficiency.
2. `Needs you`: the highest-priority operator actions, oldest gate, stale
   chains, failures, and evidence gaps.
3. `Crew`: declared human/role/skill topology with observed activity, handoffs,
   outcome state, token pressure, and last evidence overlaid.
4. `Evidence`: the existing safe event/detail surface plus bounded source
   references and explicit limitations for a selected promise, node, edge, or
   outcome.
5. `Story`: a keyboard-operable narrative sequence over the exact same ordered
   facts; no separate analysis or generated copy.

The primary action is **Inspect evidence**. Secondary actions select the time
window, move through the story, or focus a crew/skill node. There are no
mutation controls.

### Visual system

Preserve the dashboard’s current dark instrument-panel foundation and add only
the distinctions the new information requires:

| Token | Value | Role |
|---|---|---|
| Hull | `#0B1118` | page surface |
| Chalk | `#E7EEF7` | primary text |
| Signal | `#5BC0EB` | focus, links, observed flow |
| Clear | `#3DDC97` | verified outcome |
| Waiting | `#F2C14E` | operator decision or uncertainty |
| Alarm | `#FF6B6B` | violated promise or active failure |

Unknown/unmeasured state uses the existing muted neutral treatment, not a new
decorative color. Role identity may reuse the presentation’s role colors, but
state must also be carried by text, shape, border, and accessible labels.

- Display and body type remain system UI; evidence, timestamps, identifiers,
  and counts remain monospace.
- Headers are short nouns or noun phrases: `Shipyard`, `Outcomes`, `Needs you`,
  `Crew`, `Skills`, `Evidence`, `Story`. Avoid explanatory or AI-sounding
  headings.
- Use proximity to bind a claim to its outcome and evidence; use connectors to
  express lineage; use whitespace to separate operator action from passive
  telemetry.
- The signature element is the living crew/skill map. Declared membership and
  pipeline edges remain visually stable; activity pulses represent real,
  evidence-linked observations only. Reduced-motion mode retains the same state
  through static marks.
- At `390×844`, grids recompose to ordered cards and the graph becomes an
  accessible vertical route/tree rather than a squeezed desktop SVG.

## Technical Requirements

### 1. Platform-neutral inspection

- Refactor manifest discovery in `skills/shipyard/inspect.py` behind an
  explicit scheduler adapter while preserving the current systemd behavior and
  schema-v1 output.
- Add launchd discovery for Shipyard-owned `com.shipyard.*.plist` manifests,
  accepting only canonical runners rooted in this Shipyard checkout and
  validating project path, role, baked event root, schedule, and source plist.
- `skills/shipyard/shipyard.sh inspect` selects systemd or launchd using its
  existing scheduler detection instead of hardcoding
  `$HOME/.config/systemd/user` at `skills/shipyard/shipyard.sh:327`.
- Unsupported or malformed platform evidence remains explicit coverage data;
  it is never silently omitted or guessed from display names.

### 2. Minimal outcome lineage

- Add one `[telemetry] outcome_lineage` boolean. Unset/false preserves the
  current event bytes and behavior exactly; true enables only the additive
  fields/events below. Malformed values are configuration errors, not truthy.
- Generate one opaque unique `run_id` at each scheduled runner invocation and
  copy it to its `job.start`, in-run domain events, and `job.end`. Preserve
  `episode` unchanged for notification deduplication.
- Reuse explicit domain identifiers already present: `proposal_id`,
  `incident_id`, `merge_sha`, and persisted decision IDs. Never join work by
  title or timestamp proximity.
- Emit compact build item outcomes after validated result parsing with
  `run_id`, stable `work_id`, enum outcome, and optional PR/branch/commit
  references. Do not emit result prose.
- Ticket mode emits a stable relative ticket ID and accepts an explicit
  upstream work/proposal ID; it never guesses lineage from title text.
- Shoulder events share one opaque `critique_id` derived from the reviewed
  snapshot and durably record `deposited`, `deferred`, `failed`, or `expired`
  delivery disposition. They do not claim a downstream code effect without a
  future explicit work link.
- Keep single-total tokens for backward compatibility and add provider, model,
  and available input/cache/output/reasoning token classes only when already
  supplied by the harness result. No price or dollar estimate is emitted.

### 3. Content-free crew and skill relationships

Before the operator document is composed, add a bounded, content-free
relationship aggregate:

- Generalize `scripts/delegation-report.py` (or extract its parsers without
  changing its CLI) so core can count observable caller→callee and skill
  invocations from current-user Claude and Codex transcripts. Persist or return
  only provider, stable opaque actor/session IDs or declared role/harness IDs,
  skill IDs, timestamps, enum completion states when explicitly recorded, and
  counters. Never retain task descriptions, prompts, messages, tool arguments,
  results, or transcript paths.
- Distinguish declared graph edges from observed calls. Missing providers,
  absent transcript roots, parse gaps, and unsupported Hermes evidence are
  `unknown`/limitations, never zero activity or success.
- Keep the existing delegation report output and `execute-ticket` measurement
  contract backward compatible. If additional invocation markers are needed,
  use the smallest generic marker contract and regenerate coupled deck data;
  do not invent skill use from prose matching.

### 4. Shipyard-owned operator document and change metrics

- Add `dashboard/operator.py` with an independent
  `OPERATOR_VIEW_SCHEMA_VERSION = 1`, a pure deterministic composer, and a
  bounded single-flight cache for expensive inspection data.
- Add `GET /api/operator?window=24h|7d|30d`; reject every other or repeated
  query exactly like existing endpoints. Keep `/api/health`, `/api/summary`,
  `/api/events`, and `/api/stream` backward compatible.
- The response contains:
  - metadata: schema/build/rule versions, window, generated time, refresh age,
    and `fresh|stale|unavailable` inspection state;
  - `narrative`: short heading/subline, focus statement, ordered story beats,
    and operator-action copy;
  - `promises`: stable IDs, `verified|violated|unverified|not_applicable`,
    target, observed value, evidence IDs, and limitations;
  - `outcomes`: complete feature/bug chains, role-contract completion,
    reliability, operator load, and efficiency only where denominators exist;
  - `topology`: stable human/role/skill nodes, declared membership/pipeline
    edges, observed overlays, live state, last activity, and evidence IDs;
  - `changes`: only for an explicitly linked, validated `base_sha..head_sha`,
    aggregate additions, deletions, files touched, commit count, and
    product/test/docs buckets from local Git metadata without returning any
    filename;
  - `attention`, `coverage`, and bounded redacted evidence objects.
- The composer selects and redacts from `build_document()`; it never exposes
  machine paths, prompt/message/result bodies, filenames, diffs, or critique
  prose.
- Load declared roles, skills, membership, and pipeline edges from the
  generated presentation graph in `docs/shipyard-data.json`; validate it and
  report unavailable topology rather than inventing nodes.
- Promise/KPI states, thresholds, sorting, severity, wording, and limitations
  live only in core. Adapters may format dates and map semantic tokens to CSS.
- Never hold `DashboardHTTPServer.reader_lock` while running inspection. Serve
  the last good inspection snapshot on refresh failure and mark it stale.
- The operator request must not execute inspection synchronously per page
  request; use a bounded TTL and one in-flight refresh.
- Resolve Git references without a shell, reject missing/non-commit/unreachable
  or reversed ranges, and report a limitation rather than guessing a range.
  “Survived” or “durable” change may be reported only when explicit ancestry
  and revert evidence supports it; otherwise it is unknown.
- Bound the response to 200 attention items, 500 evidence objects, eight story
  beats, and a 300-second inspection TTL. Preserve deterministic priority/order
  when truncating and report truncation as coverage metadata.

### 5. Standalone/macOS thin adapter

- Replace browser-side state derivation with one operator-document fetch.
  Existing raw events may still be fetched only inside the Evidence mode.
- Render `Outcomes`, `Crew`, `Evidence`, and `Story` as in-page modes over the
  supplied document. Preserve the existing health/event evidence surface where
  it remains useful.
- The crew/skill graph renders the supplied node/edge order and supplied state
  exactly. It must not infer caller, priority, outcome, stale state, or
  actionability from raw events.
- Use safe DOM text APIs for every field. Preserve selection and scroll across
  SSE invalidation; expose unavailable/stale/parse states with a direct next
  step.
- Preserve keyboard operation, visible focus, semantic structure, contrast,
  hostile-text safety, reduced-motion equivalence, and same-origin-only
  requests.
- Browser tests inject sentinel promise/KPI/topology/narrative values that
  intentionally conflict with raw events and prove the DOM follows the core
  document, catching duplicated adapter derivation.

### 6. Stable adapter contract for Ice

- Document the versioned operator payload and compatibility rules in the
  existing dashboard/operator documentation; do not add a parallel product
  explainer.
- Provide fixture JSON and a contract test that the later Ice server adapter
  can consume without importing Python or rereading JSONL.
- Keep the server loopback-only, no-CORS, read-only, and non-embeddable. Ice
  will fetch it server-side in its own linked ticket.

## Implementation Plan

Every delegation brief below is limited to the named slice and owned files. It
must include this instruction verbatim:

> Converge honestly or report the precise blocker with the actual evidence — NEVER fake green, weaken a check, or hand-wave "should work". Run the real command, read the real file, curl the real port, and report exact output (exit codes, JSONL lines, HTTP codes), not adjectives.

Any delegated task that discovers a need for spend, outward communication,
history rewrite, destructive cleanup, or a change outside the ticket boundaries
must stop and return the decision to the orchestrator.

### Phase 1 — Launchd inspection parity (5 pts)

Introduce the scheduler-neutral manifest boundary, preserve systemd output
byte-for-byte for existing fixtures, add hermetic launchd fixtures, and route
the CLI through platform detection. Prove macOS manifests produce the same
canonical fleet/project/role evidence shape.

Delegation (≤40 lines): subagent owns `skills/shipyard/inspect.py`, the minimal
platform-selection edit in `skills/shipyard/shipyard.sh`, launchd fixtures, and
focused cases in `tests/shipyard-inspect.bats` / `tests/shipyard-status.bats`.
First capture a failing launchd-equivalence case; then implement only the
scheduler boundary and canonical validation. Return exact files, RED/GREEN exit
codes, compared schema paths, and blockers, followed by the required honesty
clause above.

Verification:

```bash
python3 -m py_compile skills/shipyard/inspect.py
bash -n skills/shipyard/shipyard.sh
bats tests/shipyard-inspect.bats tests/shipyard-status.bats
```

Observable phase DoD: equivalent hermetic systemd and launchd manifests yield
the same fleet/project/role/coverage shape; malformed and foreign plists become
limitations; every pre-existing inspect/status case remains green.

### Phase 2 — Content-minimizing lineage (5 pts)

Add the default-off telemetry gate, run IDs, explicit build/ticket lineage,
token classes, and shoulder critique disposition. Prove false/unset event bytes
remain unchanged and true produces only the allowed structured fields.

Delegation (≤40 lines): subagent owns `.agents/config.toml`, shared event/run
helpers, the smallest necessary role runners, shoulder delivery emitters, and
their focused Bats fixtures/tests. Capture RED assertions for the opted-in
shape and byte-for-byte unset/false compatibility before implementation. Return
exact changed files, exit codes, representative redacted JSONL keys, forbidden
field assertions, and blockers, followed by the required honesty clause above.

Verification:

```bash
bash -n agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh
bats tests/harness.bats tests/design.bats tests/gap-fixes.bats \
  tests/incident-reroute.bats tests/token-caps.bats \
  tests/shoulder-mode.bats tests/codex-feedback-delivery.bats
bash scripts/leak-check.sh
```

Observable phase DoD: unset/false telemetry produces byte-identical legacy
events; true joins starts, explicit domain outcomes, token classes, and critique
delivery using opaque IDs and contains none of the prohibited content fields.

### Phase 3 — Content-free crew and skill evidence (5 pts)

Extend the existing transcript measurement boundary to emit deterministic,
bounded caller→callee and skill aggregates for the operator composer. Preserve
the current report contract and turn unsupported/missing sources into coverage
limitations.

Delegation (≤40 lines): subagent owns `scripts/delegation-report.py`, dedicated
fixtures under `tests/fixtures/delegation-report/`, and focused
`tests/delegation-report.bats` / `tests/delegation-contract.bats` cases. Do not
touch dashboard UI or runner outcome logic. Return exact RED/GREEN results,
emitted aggregate keys, proof that content/transcript paths are absent, legacy
golden compatibility, and blockers, followed by the required honesty clause
above.

Verification:

```bash
python3 -m py_compile scripts/delegation-report.py
bats tests/delegation-report.bats tests/delegation-contract.bats
python3 scripts/delegation-report.py --all --json
```

Observable phase DoD: fixture calls and skill invocations match exact supplied
order/counts; Claude/Codex gaps and Hermes are honestly limited; no prose,
arguments, results, or filesystem paths cross the aggregate boundary.

### Phase 4 — Operator document and cached API (5 pts)

Implement the pure composer, presentation-topology loader, inspection cache,
redaction boundary, validated Git aggregates, and `/api/operator` endpoint.
Preserve every existing API contract and benchmark bound.

Delegation (≤40 lines): subagent owns new `dashboard/operator.py`, operator
fixtures/tests, and the minimal integration in `dashboard/server.py`; it may
consume but not change the Phase 1–3 contracts. Return schema keys,
cache/single-flight/failure evidence, exact Git range cases, redaction and
bound assertions, legacy API results, and blockers, followed by the required
honesty clause above.

Verification:

```bash
python3 -m py_compile dashboard/operator.py dashboard/reader.py dashboard/server.py
python3 -m unittest -v dashboard.tests.test_operator \
  dashboard.tests.test_reader dashboard.tests.test_server
bats tests/dashboard.bats tests/shipyard-inspect.bats
python3 dashboard/tests/benchmark_reader.py --rows 300000
```

Observable phase DoD: all three windows return deterministic schema-v1 data;
invalid queries/ranges fail closed; stale last-good inspection is explicit;
concurrent refresh is single-flight; no legacy API or reader bound regresses.

### Phase 5 — Outcomes, crew map, evidence, and story (5 pts)

Recompose the standalone UI as a thin client of the operator document, using
short headers, restrained state color, a responsive crew/skill tree, and a
deterministic narrative mode. Strengthen the browser harness with contradictory
sentinel data so adapter-owned semantics cannot regress.

Delegation (≤40 lines): subagent owns `dashboard/static/index.html`,
`dashboard/static/styles.css`, `dashboard/static/app.js`, browser fixtures, and
`dashboard/tests/browser.mjs`. Remove at least one redundant accessory. Do not
derive state in JavaScript. Return exact files, both screenshot paths,
assertion counts, focus/keyboard/reduced-motion/overflow/network evidence, and
blockers, followed by the required honesty clause above.

Verification:

```bash
node --check dashboard/static/app.js
node --check dashboard/tests/browser.mjs
WIDE_SHOTS="$(mktemp -d)"
NARROW_SHOTS="$(mktemp -d)"
node dashboard/tests/browser.mjs --browser chromium --viewport 1440x900 \
  --screenshot-dir "$WIDE_SHOTS"
node dashboard/tests/browser.mjs --browser chromium --viewport 390x844 \
  --screenshot-dir "$NARROW_SHOTS"
```

The orchestrator must inspect both final screenshots, not merely record that
the browser exited zero.

Observable phase DoD: contradictory sentinel raw/operator inputs render the
operator values and order; all four modes work at both viewports; the tree has
a semantic narrow form; focus, contrast, reduced motion, hostile text, SSE
state preservation, and same-origin behavior are visibly and mechanically
proven.

### Phase 6 — Installed Mac/Linux proof and contract handoff (3 pts)

Reinstall/restart the intended local dashboard service without disturbing any
other loopback listener, verify the operator payload and rendered modes on the
real event store, update canonical docs, publish the fixture/compatibility
contract, and hand the shipped schema/commit to the dependent Ice ticket.

Delegation (≤40 lines): subagent owns only installer-focused tests, canonical
dashboard/operator docs, the committed schema fixture, and contract handoff
notes. It may run but must not silently replace another process on port 8765.
Return exact doctor output, host/port, HTTP status/schema version, screenshot
paths, fixture checksum, docs links, and blockers, followed by the required
honesty clause above.

Verification:

```bash
bash scripts/install-dashboard.sh --install --port 8765
bash scripts/install-dashboard.sh --doctor --port 8765
curl --fail --silent --show-error http://127.0.0.1:8765/api/health
curl --fail --silent --show-error 'http://127.0.0.1:8765/api/operator?window=24h'
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py dashboard/*.py \
  skills/shipyard/inspect.py scripts/delegation-report.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py --all
git diff --check
```

Repeat the Phase 5 real-browser commands against the installed service. On
Linux, the native systemd smoke plus hermetic launchd fixture is the required
gate. A real Mac launchd smoke is recorded as external confirmation and is not
faked or made a Linux completion blocker. After local gates, push canonical
`main`, inspect `gh` CI checks, and graduate the ticket with
`scripts/ticket-lifecycle.sh`.

Observable phase DoD: the real current-platform service is healthy and serving
schema v1 plus the shared UI; the committed fixture matches the documented
contract; full local gates and remote CI are green; the completed ticket is in
its configured lifecycle folder.

## Orchestration Protocol

- Work directly on canonical `main`; this repository forbids feature
  branches/worktrees because fleet skill symlinks resolve through the canonical
  checkout.
- Preserve the owner’s unrelated `docs/styles.css` safe-area edit exactly as
  found. Never stage it in a ticket commit and name it in every hygiene check.
- At phase start, record `git status --short --branch`, HEAD, and the files
  assigned. Capture a failing focused test before implementation when the phase
  introduces observable behavior.
- One builder owns one disjoint phase slice. The orchestrator reviews the diff,
  reruns every phase command itself, checks `git diff --check` and ticket
  lifecycle, then commits only explicit phase paths with required attribution.
- Never weaken, skip, or replace a required gate to obtain green. A missing
  native Mac host remains explicit external confirmation; all available Linux,
  fixture, browser, service, and CI gates still run.
- Before install/restart, identify the current loopback listener and unit. Do
  not kill or overwrite an unrelated process. Record event-source checksums
  before/after all read-only dashboard proof.
- After each accepted phase, update the ledger with builder, commit, exact
  evidence, limitations, and any baseline variance. If a user-decision-class
  issue appears, stop and alert the owner; implementation uncertainty is not a
  reason to fabricate a decision.

## Testing Strategy

- Focused Python unit tests cover deterministic composition, scheduler
  discovery, redaction, cache TTL/single-flight/failure, endpoint validation,
  legacy rows, and source immutability.
- Focused hermetic Bats prove the default-off telemetry path first, then exact
  run/outcome/critique event fields under opt-in without network or model use.
- Existing dashboard reader/server tests remain green; health schema, summary,
  events, SSE, host validation, mutation rejection, and resource bounds do not
  change.
- Real Chromium proof at `1440×900` and `390×844` covers every mode, supplied
  state ordering, tree semantics and text equivalent, hostile text, keyboard,
  focus, contrast, overflow, reduced motion, selection/scroll preservation,
  unavailable/stale states, and same-origin traffic.
- Installed-service proof runs the platform-native installer/doctor, curls the
  loopback API, renders the real page, and leaves no headless browser or changed
  event-source bytes.
- Full repository gates include Bats, Bash/Python/JavaScript syntax, reader
  benchmark, leak firewall, deck freshness/completeness/render, ticket
  lifecycle, delegation, and `git diff --check`.

## Acceptance Criteria / Definition of Done

- [ ] `/api/operator` returns one stable schema-v1 document for each supported
      window and rejects unsupported, blank, repeated, or unknown parameters.
- [ ] Existing health, summary, events, stream, loopback, read-only, no-CORS,
      CSP, and performance contracts remain backward compatible.
- [ ] A deterministic fixture yields exact promise states, outcome chains,
      topology order, attention order, evidence IDs, limitations, and narrative
      beats; missing lineage remains `unverified`, never zero or green.
- [ ] Every claim, outcome, node, and observed edge exposes bounded evidence IDs
      or an explicit limitation explaining why evidence is unavailable.
- [ ] Content-free caller→callee and skill aggregates preserve declared versus
      observed relationships, expose source coverage, and treat unsupported
      Hermes/missing transcripts as unknown rather than zero.
- [ ] Explicit valid Git ranges produce aggregate additions, deletions, files,
      commits, and product/test/docs buckets without filenames; invalid or
      unlinked ranges remain limited/unknown and no durability claim is guessed.
- [ ] No new telemetry or operator response stores prompts, messages, diffs,
      filenames, critique prose, result bodies, or machine-private paths.
- [ ] With `[telemetry] outcome_lineage` unset or false, runner event behavior is
      unchanged; with it true, run, work, commit/PR, token-class, and critique
      disposition fields join only through explicit opaque identifiers.
- [ ] Systemd and launchd inspection fixtures produce the same canonical fleet,
      role, coverage, and limitation shapes for equivalent installations.
- [ ] The installed standalone/macOS dashboard renders `Outcomes`, `Crew`,
      `Evidence`, and `Story` from the operator document and performs no KPI,
      priority, stale, lineage, or narrative derivation in JavaScript.
- [ ] The UI uses concise aesthetic headings, restrained semantic color,
      intuitive proximity/connectors, and no explanatory AI-sounding headers.
- [ ] Wide and narrow browser proofs pass with complete keyboard access, visible
      focus, readable contrast, responsive recomposition, reduced-motion
      equivalence, no overflow, no hostile-text execution, and no external
      request origins.
- [ ] Appended events invalidate the view without losing selection/scroll;
      inspection refresh is bounded, single-flight, and serves an explicitly
      stale last-good snapshot on failure.
- [ ] One committed fixture and compatibility note are sufficient for a later
      Ice adapter to render the same ordered semantics without JSONL access or
      Python imports.
- [ ] Attention/evidence/story payloads obey the locked 200/500/8 bounds and
      inspection refresh uses the locked 300-second TTL.
- [ ] Installed service, focused tests, full repository gates, CI, cleanup, and
      ticket lifecycle checks are green; event history remains byte-identical.

## Boundaries

### Always

- Keep the service machine-local, loopback-only, read-only, no-CORS, and
  non-embeddable.
- Keep canonical raw history append-only and derive operator meaning in
  Shipyard core.
- Preserve unknown, partial, stale, unsupported, and unavailable states as
  first-class output with evidence limitations.
- Keep every telemetry addition structured, bounded, opt-in, and
  content-minimizing.

### Ask first

- Any breaking schema change after operator-view v1 is committed.
- Any proposal to enable outcome telemetry across project configs outside this
  repository or rebake/restart their live crew units.
- Any change that exposes the service beyond loopback, adds a remote transport,
  or introduces model/dollar-cost lookup.
- Any migration, deletion, or rewrite of existing event history.

### Never

- Never duplicate KPI, priority, promise, narrative, topology, or lineage
  semantics in the standalone/Mac or Ice adapters.
- Never parse raw Shipyard JSONL in the later Ice adapter or embed the
  standalone dashboard in an iframe.
- Never store prompts, messages, source diffs, filenames, critique prose,
  result bodies, or machine-private paths in the new telemetry/document.
- Never add a database, UI framework, graph-physics library, analytics service,
  or other top-level runtime dependency for this feature.
- Never claim that a critique “prevented a bug”; report only the observable
  finding, delivery, disposition, linked edit/test, and merge evidence.
- Never make raw tokens, LOC, commit count, invocation count, or critique count
  a success KPI without a verified outcome denominator.

## Dependencies

- The completed local operations dashboard and dashboard service identity work
  now merged into `main`.
- The dependent Ice adapter ticket is blocked on the committed operator-view
  schema and fixture from Phase 5.
- External services: none.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Outcome joins imply causality that the evidence does not prove | Join only explicit IDs; expose limitations and leave the promise unverified. |
| Inspect work makes each HTTP request slow or blocks event reads | Single-flight TTL cache outside `reader_lock`; serve the last good snapshot as stale. |
| Launchd parsing accepts unrelated or malicious plists | Accept only canonical Shipyard runners rooted in the configured core and validate every path/role field. |
| Default-off telemetry leaves historical or unconfigured projects incomplete | Show honest unverified states; never backfill or infer; document explicit later opt-in. |
| UI adapters slowly reacquire business logic | Contract fixtures intentionally contradict raw events and assert exact supplied DOM values/order. |
| A visually rich graph becomes inaccessible or decorative | Provide semantic text/tree equivalence, keyboard focus, reduced-motion state, and evidence links for every observed overlay. |
| Fleet-live runner edits break other projects | Gate every emitter change behind one false/unset switch and run the complete hermetic suite before each commit. |

## Out of Scope

- Implementing the Ice `/shipyard` adapter; that is a linked ticket after this
  schema ships.
- Enabling `[telemetry] outcome_lineage` in sibling project configs or rebaking
  their live units.
- Making the public presentation consume private live fleet data.
- Remote dashboard exposure, authentication, mutation controls, or owner
  notifications.
- Dollar-cost accounting, billing integrations, or inferred model prices.
- Counterfactual claims about defects that might have occurred.

## Ledger

| Phase | Plan | Builder | Commit | Evidence / notes |
|---|---|---|---|---|
| 1 | Launchd inspection parity | builder: subagent (1 inspection agent) | `ee6efb0` | RED: launchd-equivalence case exited 1 because CLI inspected the empty systemd directory. GREEN: Python compile, Bash syntax, diff/leak/deck/lifecycle gates; focused inspect/status 85/85; full repository 702/702. Canonical plist discovery excludes malformed/foreign jobs, launchd calls only exact read-only `launchctl print`, runtime failures remain unavailable/partial, and the schema-v1 systemd-slot normalization is an explicit limitation. Unrelated `docs/styles.css` remained unstaged and untouched. |
| 2 | Minimal outcome lineage | builder: subagent (1 telemetry agent) | `925b547` | RED: legacy-byte guard passed while five opt-in lineage cases failed. GREEN: 205/205 required runner/shoulder cases, 22/22 spawn cases, and full repository 720/720 in the combined Phase 2–3 tree. Unset/false stays byte-identical; true emits opaque run/work/ticket/critique IDs, explicit domain references, available numeric token classes, and observable delivery disposition. Root review replaced a relative ticket path with `ticket:<sha256>` and preserved the critic's prior malformed-TOML fallback. No sibling config was enabled; the local ignored sample is explicit false. |
| 3 | Crew/skill relationship evidence | builder: subagent (1 relationship agent) | `ccf6bb4` | RED: five operator-mode cases failed while all 59 legacy cases stayed green. GREEN: focused delegation 66/66, compile/leak/diff clean, legacy goldens byte-identical, and combined full repository 720/720. Real content-free report: Claude 428 call edges/170 skill rows available; Codex 174/35 partial with marker-coverage limitation; Hermes unknown/unsupported. Distinct callees and sessions are opaque hashes; missing roots are unknown, and no prompt, description, argument, result, transcript path, or secret crosses the boundary. |
| 4 | Operator document/API and Git metrics | builder: inline (root after stalled builder; 1 independent review subagent) | `0a245ba` | RED: the new operator test module failed import before `dashboard/operator.py`; the first real Bats launch then exposed and fixed the module/stdlib name collision. GREEN: 56/56 operator/reader/server unit cases, focused dashboard/inspect 85/85, 300k reader benchmark in 1.362s at 237.4 MiB with checksum unchanged, and full repository 720/720. Independent review found and root closed pure-composer, Git-timeout, 2,000-row truncation, stable-promise, human-node, token-denominator, and global single-flight gaps. Real 24h proof reached fresh schema v1 with 8 stable promises, 40 attention rows, 45 nodes, 21 observed edges, 500 bounded evidence rows, zero dangling references, no private path/content terms, and an honest `explicit_git_range_unavailable` limitation. |
| 5 | Shared standalone/macOS UI | builder: subagent (1 UI builder + 1 read-only inventory agent) | pending phase commit | RED: the contradictory operator sentinel found the missing Outcomes mode while the retained legacy dashboard still passed syntax. GREEN: root reran 20/20 server and 60/60 operator/reader/server units; Chrome 147 passed 58 desktop and 59 narrow assertions with exact core order/state winning over contradictory raw evidence, all four keyboard modes, hostile text inert, raw events fetched only in Evidence, selected IDs plus window/list scroll preserved over SSE, 3px focus, reduced-motion static activity, same-origin requests only, no mutation controls, and no overflow (0px desktop, -15px narrow). Root inspected `/tmp/shipyard-wide.q7OWne/dashboard-1440x900.png` and `/tmp/shipyard-narrow.d2FruU/dashboard-390x844.png`: restrained dark semantic color/shape, short headings, collapsed outcome collections, and the 390px vertical crew route all match the locked design. The first full run correctly caught one retained HTTP smoke expecting the retired `Fleet operations` h1; its one-line assertion now pins `Shipyard`, focused dashboard is 8/8, and the rerun is full 720/720. Staged leak, Node syntax, diff, deck, and lifecycle checks pass; browser/server processes cleaned. |
| 6 | Installed proof and Ice contract handoff | — | — | pending |

Run this ticket with the `execute-ticket` skill.
