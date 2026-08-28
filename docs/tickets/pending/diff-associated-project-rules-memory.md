# Add diff-associated project rules memory

- **Created:** 2026-08-27
- **Owner:** wabbazzar
- **Status:** BUILT — locally verified; awaiting Ice-owned `main` integration
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 21 (5 phases, cap 5/phase)
- **Refs:** remote `main` baseline `595471d`; `agents/release/critic-watch.sh:648-667,743-848,963-1157`;
  `agents/release/specialist-review.py:53-162`; `skills/polish-ticket/SKILL.md:79-126,297-326`;
  `skills/shipyard/shipyard.sh:39-121,360-407,655-665`; `install.sh:182-197,494-893`

## Summary

Give every Shipyard-managed project a durable, diff-associated memory of prior failures without
copying retrieval machinery into each repository. A project owns one tracked, human-reviewable rules
ledger; Shipyard owns the ledger schema, validation, indexing, hybrid retrieval, fresh-context review,
diff-bound receipts, invalidation, diagnostics, and stop-gate integration.

The memory is consulted twice: before a ticket or fix is made executable, and again against the exact
real hunks before the change may pass required shoulder review. Similarity produces candidates, never
truth: every finding must cite the original project ledger entry and a fresh reviewer must decide
whether the historical rule applies to the current change.

## Problem / background

Shipyard already has the right review shape but not the right memory mechanics. The release watcher
extracts real changed hunks and selects specialists deterministically
(`agents/release/specialist-review.py:53-77,81-135`), then starts a cold, review-only specialist with a
bounded project decision log and the exact matching hunks
(`agents/release/critic-watch.sh:981-1015,1025-1113`). This protects against author-context bias, but
the complete decision log is injected as prose and truncated to a fixed character budget
(`agents/release/critic-watch.sh:1035-1046`). As a project accumulates hundreds of incidents, the
relevant old failure can fall outside that budget or remain present but unassociated with a new diff.

The specialist role correctly treats project memory as project-owned evidence and requires cited
judgments (`agents/specialist/role.md:23-37,39-66`). Its current decision-log template, however, is a
free-form document organized into five prose sections
(`agents/specialist/decision-log.template.md:1-46`). It has no stable record identity, structured
associations, retrieval score, exact-diff receipt, or automatic invalidation after the author changes
the patch.

Shipyard core must remain generic and hold no project state (`CLAUDE.md:3-8`). Therefore the solution
cannot put one project's rules into Shipyard, add a project-specific parser to a Shipyard runner, or
commit an opaque vector database beside source code. The project supplies facts; Shipyard supplies
all mechanics.

## Confirmed assumptions

- The existing generic critic remains first and cold-context; historical memory is an additional
  review input, not author transcript and not a replacement critic
  (`agents/release/critic-watch.sh:981-985`).
- Review routing is based on actual diff hunks, not merely queued filenames
  (`agents/release/specialist-review.py:53-77`; `tests/specialist-watch.bats:91-113`).
- Project manifests are data-only and path-contained. Shipyard validates them without evaluating
  values or fetching network content (`agents/specialist/validate-manifest.py:40-51,84-118`).
- New capability must be opt-in, and an unset configuration must preserve today's behavior
  byte-for-byte (`CLAUDE.md:91-99`).
- For hundreds or low thousands of records, a local derived index is sufficient. This ticket does
  not require a hosted vector database, a daemon, or a sixth lifecycle agent.
- Historical similarity is recall assistance, not proof. Only the cited source ledger entry, current
  code, current diff, and current verification can support a blocking finding.

## Objective

When a configured project plans or authors a change, Shipyard automatically retrieves the most
relevant historical rules from that project's ledger, gives those bounded records plus the current
scope or exact diff to a fresh review-only model invocation, and emits an auditable verdict bound to
the exact inputs. A stale receipt, unavailable required retrieval channel, malformed ledger, or
unresolved applicable blocking rule cannot silently pass.

## Ownership boundary

| Concern | Owner | Durable location |
|---|---|---|
| Rule/incident facts, wording, severity, citations, supersession | Project | `.agents/rules-ledger.jsonl`, tracked in the project |
| Opt-in and policy mode | Project | Existing `.agents/config.toml` |
| Record schema and safe parser | Shipyard | Shipyard source and tests |
| Normalization, exact/FTS/vector indexing, ranking, query explanation | Shipyard | Shipyard source; derived cache only |
| Embedding adapter/model selection contract | Shipyard | Shipyard source/config contract; never project scripts |
| Planning-time query and fresh reviewer invocation | Shipyard | `polish-ticket`/ticket pipeline |
| Exact-diff query, receipt, invalidation, finding merge, stop gate | Shipyard | Existing release shoulder path |
| Index files, vectors, query packets, and receipts | Shipyard runtime | Untracked Shipyard cache/state keyed by project and digest |
| Project-specific mechanics, hooks, parsers, generated DBs | Nobody | Forbidden |

The project ledger is the only source of truth. Every database/vector artifact is reproducible from
that file and disposable. Cloning the project plus installing the same Shipyard version is enough to
rebuild memory; copying a developer's cache is never required.

## Decisions

### Locked

| Decision | Rationale |
|---|---|
| Shipyard owns all executable mechanics; each project owns only its ledger data and opt-in | Prevents hundreds of repositories from drifting onto subtly different memory implementations |
| Use one schema-versioned JSONL ledger at `.agents/rules-ledger.jsonl` | Stable IDs and per-record diffs make entries reviewable, citeable, mergeable, and incrementally indexable |
| Keep all indexes and receipts out of tracked project files | Opaque vectors and runtime state are derived artifacts, not code-review inputs |
| Use hybrid retrieval: deterministic metadata matches, full-text search, and vectors | Exact identifiers catch known recurrence; FTS catches shared terms; vectors widen recall for renamed or paraphrased mechanisms |
| Fuse channel ranks and expose the reason each record matched | A score without a path/tag/term/vector explanation is not an auditable gate |
| Query once during planning and again against the exact post-edit diff | The first pass changes the plan; the second catches implementation drift and newly introduced hazards |
| Give every nontrivial configured code fix a fresh historical-risk reviewer | A new invocation has no author transcript and must re-ingest the bounded retrieved packet for that exact fix |
| Similarity alone never blocks or closes a finding | Retrieval nominates records; a cited fresh-review disposition and current evidence decide applicability |
| Bind every accepted review receipt to the diff, ledger, index/model, policy, and reviewer inputs | Any change to code or memory invalidates an old clean verdict instead of laundering it forward |
| No hosted vector service or memory daemon in the first implementation | The expected ledger size does not justify a new operational dependency or availability boundary |
| Preserve existing specialist decision logs | The structured rules ledger complements, and does not silently migrate or delete, narrative subsystem rationale |

### Open with defaults

| Question | Default |
|---|---|
| Derived cache root | Shipyard's platform cache directory, keyed by canonical repository identity; never the project worktree |
| Vector implementation | Shipyard-owned `stdlib-hash-ngram-v1`: Unicode NFKC + case-fold, word 1–2 grams and character 3–5 grams, signed BLAKE2b hashing into 2,048 dimensions, L2 normalization, and in-process cosine; no native extension, learned model, network, or external database |
| Full-text implementation | Probe SQLite FTS5 and use it when present; otherwise use a deterministic pure-Python BM25 fallback and record the selected backend in the index/receipt |
| Vector-backend availability | The required `stdlib-hash-ngram-v1` backend uses only Python's standard library; inability to construct it is an index failure in either policy mode, not permission to omit the vector channel |
| Rank fusion | Deterministic reciprocal-rank fusion over exact, FTS, and vector channels, followed by stable severity/recency tie-breaks |
| Candidate bounds | Retrieve at most 20 records per channel, fuse to at most 12, and inject at most 8 full records into the reviewer prompt |
| Nontrivial fix boundary | Include source, test, build, workflow, infrastructure, and configuration hunks; exclude generated files and prose-only diffs unless a configured rule has an exact path/tag match |
| Planning integration | `polish-ticket` queries ticket text, explicitly named files/symbols, acceptance gates, and failure signatures before executable phases are finalized |

### User-decision class

None. The operator explicitly chose Shipyard-owned mechanics with project-local ledgers. The defaults
above preserve an executable implementation path without requiring a vector vendor or a central
service.

## Technical requirements

### Project ledger contract

- The exact opt-in surface is `[memory] mode = "advisory"|"required"` in `.agents/config.toml`.
  The whole table being absent means off and preserves legacy bytes/model calls. Optional keys are
  `ledger = ".agents/rules-ledger.jsonl"`, `vector_backend = "stdlib-hash-ngram-v1"`,
  `max_channel_candidates = 20`, `max_fused_candidates = 12`, and `max_prompt_records = 8`; these are
  the exact defaults and unknown keys/values fail config validation when the table is present.
- Shipyard defines and version-controls the JSON Schema (or equivalently strict parser contract) for
  one JSON object per line. Projects must not copy that schema or parser into their own repository.
- Every record contains: `schema_version = 1`; `id` matching `[A-Z][A-Z0-9_-]{1,63}`;
  RFC 3339 UTC `occurred_at`; `kind` in `incident|regression|near_miss|decision`; `severity` in
  `note|warn|block`; `status` in `active|superseded`; and
  concise `summary`, causal `mechanism`, imperative `rule`, `required_evidence`, structured
  `associations`, `remediation`, and one or more project-relative or Git commit/ticket `sources`.
- `associations` supports bounded arrays for repository paths/globs, symbols, subsystems, lifecycle
  phases, state transitions, error signatures, technologies, and free tags. Values are treated only
  as data; no ledger value may be evaluated as a command, regex program, URL fetch, or code.
- Each `source` is an exact object `{kind, ref}` where `kind` is `path|commit|ticket|issue`; paths are
  safe project-relative POSIX paths and other refs are inert bounded strings. `associations` has the
  exact optional array keys `paths`, `symbols`, `subsystems`, `phases`, `state_transitions`,
  `error_signatures`, `technologies`, and `tags`; unknown association/source keys are invalid.
- Records may name `supersedes` as a bounded array of other stable IDs. Superseded entries remain
  citeable/searchable but cannot block. Missing targets, self-links, multiple active superseders, and
  direct or transitive supersession cycles are invalid.
- Limits are fail-closed and tested: 10,000 records; 256 KiB per JSONL line; 32 MiB ledger; 64
  association values per key; 2,048 Unicode code points per prose field; 16 source objects; and 256
  characters per inert scalar association/source ref.
- Validation rejects duplicate IDs, unknown keys, unsafe paths, invalid severities/statuses, missing
  citations, oversized fields/records, NUL bytes, and customer data/secret-shaped content detectable
  by Shipyard's existing safety gates. A line number and record ID identify every failure.
- `shipyard memory init|validate|status|query` is the exact CLI family, implemented by the shared
  Shipyard CLI calling a single generic core helper; `query` accepts exactly one of `--scope-file` or
  `--diff-file` and emits stable schema-v1 JSON. Initialization creates an empty ledger and config
  pointer; it never
  invents project incidents or calls a model/network.
- Shipyard may offer an explicit import assistant for existing Markdown/ticket registers, but the
  generated entries must be reviewed and committed by the project. There is no implicit scrape on a
  review path and no project-specific import code in Shipyard.

### Derived index and retrieval

- Normalize each active ledger record into a canonical retrieval document while preserving the
  original record bytes and source line for citation. Hash the complete canonical ledger before any
  query.
- Store derived data under the platform cache root
  `${XDG_CACHE_HOME:-<platform-user-cache>}/shipyard/memory/<sha256(realpath-worktree)>/`; receipts are
  per worktree and never keyed by remote URL alone. Maintain an untracked, atomic, rebuildable index
  containing structured metadata, full-text terms,
  embedding vectors, ledger digest, schema version, Shipyard version, embedding adapter/model ID,
  and normalization version. A partial or mismatched index is never queried.
- Rebuild to a temporary index and publish atomically after validation. Concurrent authors may read
  the last complete matching index or wait on one bounded builder; they may not observe a half-built
  cache or race two publishers into inconsistent state.
- Extract query features from the scope/diff using Shipyard code: changed paths, hunk text, symbols,
  imports/dependencies, test names, error/status strings, state transitions, and ticket terms. Do not
  add a project-owned extraction script or require the author to hand-tag every patch.
- Run deterministic exact association and FTS/BM25 on every eligible query. Run vector association
  using `stdlib-hash-ngram-v1`. This improves lexical/structural association and rename tolerance but
  makes no learned-semantic or arbitrary-paraphrase claim. Merge results with stable rank fusion and return, for
  every candidate, its ledger ID, source citation, channel ranks/scores, exact matched associations,
  and a bounded excerpt of the rule/mechanism/remediation.
- Embeddings and excerpts must exclude secrets and customer/source-record content. The ledger itself
  must contain aggregate engineering evidence only.

### Planning-time memory gate

- Extend the ticket hardening path that already discovers project specialists to query project rules
  before implementation phases become executable. The review packet contains only the bounded ticket
  scope, relevant code references, retrieved ledger records, project gates, and output contract.
- Preserve the stable fused-candidate order and define
  `review_set = candidates[:max_prompt_records]`. Start a fresh review-only invocation only for a
  nonempty review set. It returns exactly one disposition per review-set ID and no other IDs:
  `applies`, `requires_evidence`, `falsified`, `informational`, or `superseded`, each with the exact
  current path/contract evidence supporting that disposition.
- Record candidate IDs beyond `max_prompt_records`, in order, as bounded out-of-packet coverage; they
  receive no disposition. This configured bound is not itself a stage failure, but any omission makes
  coverage `bounded`, never `full` or `clean`, in advisory and required mode alike. Required mode may
  not claim stronger coverage.
- Applicable rules become explicit requirements, tests, or preflight gates in the ticket. The ticket
  records ordered candidate IDs, review-set IDs, omitted IDs, dispositions, and citations, not vectors
  or model prose presented as fact.
- Validate both successful zero-candidate shapes without a model call. They share ready/valid query
  identity, features/limits, `candidate_count = 0`, `candidates = []`, and no errors: an empty active
  ledger has `index = null`, while a nonempty indexed ledger with no match has a complete index object.
  Neither shape has candidate citations; any count/index inconsistency is invalid.
- A clean planning receipt cannot satisfy the post-edit gate because it is not bound to real hunks.
- `polish-ticket` calls the deterministic `shipyard memory query --scope-file <bounded-ticket-copy>`
  first, then delegates the returned records to a fresh review subagent. Missing or malformed query or
  reviewer evidence is an explicit blocker before the existing Decisions auto-gate only in required
  mode. Advisory mode attempts the stage, records query/reviewer degradation beside the affected phase,
  proceeds without completion as an auto-gate precondition, and cannot claim clean/full-memory coverage.

### Exact-diff shoulder gate

- Reuse the release watcher's existing real-hunk extraction and cold review boundary. Do not add a
  new timer, daemon, lifecycle role, capture hook, or project runner.
- Normalize the exact diff digest from UTF-8 bytes of the complete `full_diff` already assembled by
  `agents/release/critic-watch.sh`, preserving hunk order and LF line endings and binding the selected
  base identity. Validate memory receipts before the existing cached-delivery early return so a
  ledger/config/backend change cannot reuse stale findings.
- After the generic critic and before required feedback is delivered/consumed, retrieve rules against
  the complete eligible diff generation and start one fresh historical-risk reviewer. Its prompt is
  bounded and contains no author transcript, hidden chain of thought, or unrelated ledger entries.
- The reviewer must cite a retrieved ledger ID and current hunk path for every finding. It must state
  whether the historical mechanism is reproduced, prevented by a named guard, or owed a specific
  deterministic test. Uncited generic advice is not a rules-memory finding.
- Merge normalized findings into the existing shoulder delivery/stop-gate path. A high similarity
  score with a `falsified` current-evidence disposition does not block; an applicable `block` severity
  rule with missing required evidence does.
- One review covers one exact normalized diff generation. A later edit always generates a new digest
  and a new invocation; cached model verdict text is never reused across diff digests.
- Memory reviewer output uses `block|path|RULE_ID|message`, `warn|...`, or `note|...`; the core parser
  rejects unknown/unretrieved IDs and converts valid output to the existing three-field finding only
  after preserving rule ID/disposition in the receipt. Required-mode failures preserve the queue and
  write the existing required-feedback status; they do not rely solely on the stop gate's `block|`
  grep.
- Bound generic + specialist + memory shoulder work to one configured whole-review deadline, pass the
  remaining budget into every model spawn, and account tokens from successful and failed stages. An
  exhausted memory stage is explicit incomplete/degraded evidence, never a silently skipped review.

### Receipt, invalidation, and observability

- Emit a machine-readable runtime receipt with: canonical project identity, diff/scope digest,
  ledger digest, schema/normalizer version, index digest, embedding adapter/model ID, policy mode,
  query feature summary, retrieved IDs plus channel explanations, reviewer invocation identity,
  dispositions/findings, verdict, timestamps, and degraded/error state.
- Receipt validity requires equality of every bound digest/version and successful delivery through
  the owning workflow. Changing a hunk, ledger entry, retrieval configuration, normalization version,
  embedding model, or required project gate invalidates it.
- `shipyard status`/doctor reports opt-in state, ledger validity/count/digest, active vs superseded
  counts, index freshness, embedding availability, most recent exact-diff receipt, degradation, and
  actionable rebuild/error text without exposing ledger prose by default.
- Required mode is fail-closed for malformed/missing ledgers, stale/partial indexes, unavailable
  configured retrieval, malformed reviewer output, or receipt mismatch. Advisory mode surfaces the
  same states loudly but does not become a new stop gate.
- Projects with no memory configuration and projects with an empty initialized advisory ledger retain
  the legacy critic/specialist path without an extra model call.

## Implementation plan

### Phase 1 — ledger contract, scaffold, and validation (points: 4)

- Add the generic schema/parser, safe size/path/value validation, canonical normalization, and
  project opt-in config contract to Shipyard.
- Add deterministic `memory init`, `validate`, and `status` surfaces without model or network calls.
- Prove duplicate, malformed, unsafe, oversized, superseded, and empty-ledger behavior while leaving
  unconfigured projects byte-identical.

Delegation: subagent — own the schema/scaffold/validation slice and return no more than 40 lines with
files changed, failing-first fixtures, exact commands/exit codes, and blockers.

Gate classes: CLI/config compatibility, parser/path safety, schema fixtures, shell/Python syntax,
leak check.

### Phase 2 — atomic hybrid index and explained retrieval (points: 5)

- Implement project/digest-keyed derived cache, exact metadata index, FTS, embedding adapter, in-process
  vector search, stable rank fusion, candidate bounds, and query explanations.
- Make builds atomic and concurrency-safe; make stale, corrupt, partial, and model-mismatched indexes
  impossible to treat as current.
- Add hermetic deterministic embedding stubs plus fixed-corpus ranking tests; production tests make no
  network/model call.

Delegation: subagent — own indexing/retrieval and concurrency fixtures; return no more than 40 lines
with the index identity, ranked fixture IDs/reasons, race result, commands/exit codes, and blockers.

Gate classes: deterministic ranking, atomic publication, concurrent build/read behavior, cache
invalidation, bounded resource use.

### Phase 3 — planning-time historical-risk review (points: 4)

- Wire retrieval and one fresh review-only invocation into applicable ticket polish/preflight.
- Normalize per-record dispositions and materialize applicable historical rules as cited ticket
  requirements/gates.
- Preserve the no-ledger and both no-candidate index shapes, enforce the bounded review-set/omission
  contract, and make required/advisory degradation and gate behavior explicit.

Delegation: subagent — own planning integration and tests; return no more than 40 lines with exact
trigger/no-trigger cases, disposition normalization, ticket evidence, commands/exit codes, and
blockers.

Gate classes: skill contract, project-config compatibility, bounded prompt, malformed model output,
no-model fixtures.

### Phase 4 — exact-diff review, receipts, and stop-gate integration (points: 5)

- Add diff feature extraction/retrieval after real-hunk assembly and invoke a new reviewer for each
  eligible diff digest.
- Emit and validate receipts, merge cited findings, invalidate on every bound input change, and reuse
  existing delivery/required-feedback semantics.
- Prove no false reuse across edits, ledgers, projects, worktrees, harnesses, or embedding model IDs.

Delegation: subagent — own shoulder integration and receipt tests; return no more than 40 lines with
diff hashes, invocation counts, invalidation matrix, delivered findings, commands/exit codes, and
blockers.

Gate classes: shoulder queue/watcher, multi-harness delivery, receipt integrity, fail-closed required
mode, exact real-hunk scope.

### Phase 5 — adversarial replay, doctor, and adoption docs (points: 3)

- Add a fully synthetic held-out race-condition replay: the ledger omits the final incident but
  contains earlier related non-atomic state-transition failures; a bad read-check-write diff must
  retrieve them and require an atomic guard plus a deterministic interleaving test.
- Prove an atomic guarded diff can falsify the same candidates with cited evidence, and an unrelated
  prose diff incurs no reviewer call.
- Document the ownership split, ledger authoring/migration workflow, required/advisory rollout,
  cache disposal/rebuild, receipt interpretation, and honest coverage boundary.

Delegation: subagent — own the end-to-end fixture and documentation; return no more than 40 lines with
bad/good/unrelated verdicts, reviewer counts, doctor output, commands/exit codes, and blockers.

Gate classes: end-to-end hermetic replay, doctor, full Bats suite, syntax, leak check, deck freshness.

Every delegated phase carries this clause:

> Converge honestly or report the precise blocker with the actual evidence — NEVER fake green,
> weaken a check, or hand-wave "should work". Run the real command, read the real file, and report
> exact output and exit codes, not adjectives. If it needs spend, an outward-facing action, or a
> destructive change, stop and report instead.

## Testing strategy

- Add failing-first Bats/Python fixtures alongside `tests/specialist-watch.bats`,
  `tests/shipyard-add-specialist.bats`, `tests/polish-specialist-routing.bats`, and the shoulder harness
  suites. All ranking/model behavior uses deterministic local stubs; CI makes no network or live-model
  call.
- Pin a small golden corpus where exact, FTS, and vector channels retrieve different records; assert
  stable fused ordering and machine-readable match reasons rather than only checking that some result
  exists.
- Exercise empty, duplicate-ID, malformed JSON, unknown schema/key, unsafe path, oversized record,
  secret-shaped content, supersession cycle, stale digest, corrupt cache, partial atomic publication,
  concurrent builder, unavailable embedder, and changed-model cases.
- Exercise one planning scope and multiple sequential diff generations. Assert a new model invocation
  and receipt after every changed diff digest, zero invocation for the unchanged already-receipted
  digest only when the complete receipt remains valid, and no cross-project/worktree receipt reuse.
- Exercise `required` and `advisory` modes independently. Required failures preserve the review queue
  and block; advisory failures deliver an explicit warning and never claim full-memory coverage.
- Exercise `max_fused_candidates > max_prompt_records`: dispositions cover exactly the deterministic
  review set, omitted IDs remain ordered and undispositioned, and neither mode claims full coverage.
- Exercise both valid zero-result shapes (`active_count = 0` with null index and an indexed active
  ledger with no match), plus the two inverse index/count mismatches. Required completion blocks before
  specialist/Decisions; advisory query or reviewer failure records degradation and proceeds.
- Run focused tests per phase and the repository gates from `CLAUDE.md:44-55`: `bats tests/`, leak
  check, deck freshness, shell/Python syntax, and optional deck render.

## Definition of Done

- [x] A project can opt in with one tracked `.agents/rules-ledger.jsonl`; it contains data only and
      requires no project-owned script, hook, schema, index, database, or generated vector file.
- [x] Shipyard validates, normalizes, indexes, queries, explains, and rebuilds the ledger using generic
      core mechanics, with derived state outside the project worktree.
- [x] Exact metadata, FTS, and vector channels participate in deterministic bounded retrieval and each
      returned rule names its channel evidence and original source citation.
- [x] Ticket polish queries the ledger before executable implementation scope is finalized and records
      applicable rule IDs as explicit requirements/gates.
- [x] Every eligible exact diff generation receives a fresh, transcript-free historical-risk review;
      a changed diff cannot reuse the previous verdict.
- [x] Similarity never becomes authority: findings cite project rule IDs plus current hunk evidence,
      and reviewers can explicitly falsify irrelevant historical candidates.
- [x] Exact-diff receipts bind every specified input/version and are invalidated by code, ledger,
      policy, index, normalizer, model, or gate changes.
- [x] Required mode fails closed and advisory mode reports honest degradation for every specified
      ledger/index/reviewer/receipt failure.
- [x] Unconfigured projects retain existing behavior byte-for-byte, with no new model/network call.
- [x] The synthetic held-out race replay retrieves earlier related failures for an unsafe diff,
      requires atomicity plus a deterministic interleaving test, accepts cited prevention evidence,
      and ignores an unrelated prose diff.
- [x] Doctor exposes memory readiness/freshness without printing project ledger content, secrets, or
      customer data.
- [x] Focused tests and all repository gates are green, with any pre-existing failure reported
      separately and never weakened.

## Boundaries

### Always

- Keep project facts in the project and generic mechanics in Shipyard.
- Use the original ledger record and current evidence as authority; expose retrieval uncertainty.
- Keep reviewers read-only, cold-context, bounded, and attached to an existing lifecycle workflow.
- Preserve stable record IDs and supersession history so old receipts/findings remain explainable.

### Ask first

- Adding a paid/hosted embedding provider, transmitting ledger text to a new external service, or
  installing a native vector extension/model outside the existing Shipyard dependency policy.
- Mutating a project's existing narrative decision log or auto-importing historical incidents into a
  committed ledger.
- Enabling required mode in an installed project or changing its stop-gate policy.

### Never

- Never centralize project rules in the Shipyard repository or a shared cross-project corpus.
- Never commit vector indexes, embeddings, query packets, receipts, customer data, source records,
  credentials, or model transcripts to a project.
- Never execute ledger values, let vector similarity alone block, or let a reviewer invent an
  uncited historical rule.
- Never add a sixth lifecycle agent, another file watcher, a memory daemon, or project-specific
  retrieval code.
- Never silently pass required review with a missing/stale index, invalid receipt, unavailable
  reviewer, or malformed ledger.

## Dependencies

- Existing release shoulder real-hunk extraction, cold generic review, specialist prompt assembly,
  finding merge, required-feedback gate, and multi-harness delivery.
- Existing `polish-ticket` specialist discovery/invocation contract.
- A separately reviewed project-adoption ticket for each repository that migrates historical records
  or enables required mode; Shipyard core ships no project's ledger contents.

## Risks and mitigations

- **Semantic false positives:** bound candidates, show channel reasons, and require a fresh reviewer
  to cite current evidence or falsify the association.
- **Association false negatives:** combine exact metadata, FTS/BM25, and hashed n-gram vectors;
  exercise held-out terminology/rename fixtures instead of claiming learned semantic paraphrase.
- **Prompt growth:** inject only the bounded fused records, never the whole ledger, and retain stable
  IDs/citations for follow-up inspection.
- **Stale clean verdicts:** cryptographically bind receipts to all material inputs and never reuse
  across diff generations.
- **Concurrent index races:** validate first, build to a temporary destination, publish atomically,
  and test simultaneous authors.
- **External model/privacy risk:** default to a Shipyard-owned local adapter contract; any new hosted
  provider is ask-first and ledger policy forbids customer/source-record content.
- **Rule drift or contradiction:** stable IDs, explicit supersession, schema validation, and cited
  reviewer dispositions keep disagreement visible rather than allowing last-write-wins prose.
- **Adoption burden:** provide scaffold, validator, status/doctor, and explicit reviewed import while
  keeping the sole committed artifact small and human-editable.

## Out of scope

- Populating or rewriting any project's historical ledger in this core ticket.
- Automatically converting every narrative decision, ticket comment, or Git commit into a rule.
- Replacing code review, deterministic tests, specialist live-source review, or project gates.
- Cross-project retrieval, shared embeddings, organization-wide analytics, or a hosted memory service.
- Autonomous remediation, code generation, commit, deploy, or cloud mutation based on a retrieved
  incident.
- Guaranteeing that semantic retrieval finds an incident whose ledger record lacks enough causal or
  association detail to connect it to the current change.

## Ledger

- Phase 5 verification — `builder: inline after delegated design/review`. The synthetic held-out replay
  retrieves two earlier atomicity failures for an unsafe read-check-write hunk, emits cited atomic-
  guard/interleaving requirements, accepts a guarded hunk only with explicit falsification evidence,
  and makes no memory-review call for unrelated prose. Status/doctor expose bounded readiness,
  freshness, receipt, and degradation metadata without ledger prose. README, install, adaptation,
  shoulder, skill, and generated deck material document project/Shipyard ownership, advisory-to-
  required rollout, rebuild/disposal, receipts, and the hash-ngram recall boundary.
- Phase 4 verification — `builder: inline, independently reviewed and corrected`. Exact-diff memory
  now runs inside the existing release watcher after real-hunk assembly and generic review, uses the
  existing fresh spawn/delivery/stop-gate path, and binds project, base, diff, config, gates, ledger,
  index/backend, policy, reviewer, dispositions, findings, and delivery in a private atomic receipt.
  Required failures retain the queue; advisory failures emit explicit degradation. Review found and
  closed default-reviewer identity ambiguity, staged-base drift, live policy-promotion races, failed-
  invocation token undercounting, post-review binding races, and delivery-finalization receipt loss.
  The last correction preserves completed invocation/disposition evidence in a degraded delivered
  receipt while rejecting impossible incomplete/completed hybrid receipts; the independent re-audit
  reported no remaining concrete defect.
- Final local verification — the combined exact-diff/review/status matrix is 36/36; the install and
  lifecycle matrices are 24/24; syntax, Python compilation, `git diff --check`, and leak-check exit 0.
  The complete 925-test Bats run has 917 non-failing outcomes (915 pass, 2 documented skips) and the
  same eight pre-existing dashboard-helper startup failures as untouched `595471d`: tests 76 and
  78–84. No feature-owned or newly introduced test failed. No network, hosted model, installed
  project, active orchestrator, or runtime fleet was invoked or mutated during verification.
- Phase 3 verification — `builder: subagent (1 agent), independently reviewed and corrected before
  commit`. Planning-time memory now preserves the unconfigured legacy path, validates both empty-
  ledger and indexed-no-match zero-result shapes without a reviewer, defines the bounded review set,
  records ordered omitted IDs without overstating coverage, and separates required blockers from
  advisory degradation before specialist/Decisions handling. Review found and closed contradictions
  between fused/prompt limits, mode-specific `requires_evidence`, zero-result index shapes, and the
  auto-gate precondition. The orchestrator independently reran the 13-case polish contract and diff
  check; both exited 0.
- Phase 2 verification — `builder: subagent (1 agent), independently reviewed and corrected before
  commit`. The hybrid query/cache suite is 10/10 and the combined Phase 1+2 memory matrix is 23/23.
  Independent review found and closed semantic-but-valid cache corruption, source-layout drift,
  cross-digest pathname races, unsafe cache containment/modes, writable-ancestor replacement, and a
  marked-cache subtree swap during repair. The final cache uses immutable digest-named indexes,
  validates cached rows and FTS contents, retains the validated SQLite connection for querying,
  accepts only root-owned system aliases/sticky ancestors, and descriptor-binds marked-root
  privatization before revalidating device/inode/owner/mode. The orchestrator independently reran
  the 23 focused cases, Python compilation, diff check, and leak check; all exited 0.
- Phase 2 plan — `builder: subagent (1 agent)`. Extend the generic Python core with a worktree-keyed,
  atomically published derived index; deterministic exact metadata, FTS5/pure-Python BM25, and
  `stdlib-hash-ngram-v1` vector channels; stable rank fusion and per-candidate explanations; and a
  bounded safe query-input contract. Add failing-first golden ranking, fallback, invalidation,
  concurrency, and partial/corrupt-cache fixtures in `tests/memory-retrieval.bats`. The subagent owns
  only the core helper and this new test file; root will independently review and rerun gates.
- Phase 1 plan — `builder: subagent (1 agent)`. In the isolated remote-main clone, add the generic
  standard-library ledger/config core, wire the exact `shipyard memory init|validate|status|query`
  command family far enough for init/validate/status, and add failing-first hermetic CLI/schema tests.
  The subagent owns only `agents/lib/rules-memory.py`, `skills/shipyard/shipyard.sh`, and
  `tests/memory-cli.bats`; the orchestrator will independently rerun all focused and repository gates
  before the commit.
- Phase 1 verification — `builder: subagent (1 agent), independently reviewed and corrected before
  commit`. The pre-change CLI fixture was red at 0/8 because `memory` was unknown. The final schema
  suite is 13/13 and the adjacent status/add-specialist matrix is 17/17. Review found and closed
  unhashable-enum crashes, non-integer schema acceptance, lone-surrogate canonicalization crashes,
  ledger symlink/FIFO handling, safety-pattern drift, and the stat/open pathname race. Ledger reads
  now use one no-follow/nonblocking descriptor through `fstat` and consumption. The orchestrator
  independently reran all 30 focused cases, shell syntax, Python import, diff check, and leak check;
  all exited 0. No network, model, installed-project, or live-fleet mutation occurred.
- 2026-08-27 draft — architecture locked to Shipyard-owned mechanics and project-owned rules data.
  The design extends the current specialist/release contracts rather than adding a new service or
  lifecycle role. No implementation, project adoption, model call, network call, or runtime-state
  mutation occurred while drafting this ticket.
- 2026-08-27 polish preflight — `builder: inline (ticket hardening in an already-read file)`. Remote
  `main` was fetched at `595471d`; the active fleet checkout was intentionally not touched because it
  contained unrelated release-critic edits. Focused existing specialist/polish/Shipyard tests were
  green in read-only preflight; leak, deck freshness, and shell syntax exited 0. The macOS full-Bats
  baseline was rerun with `/bin` before Homebrew Bash after the documented preprocessing slowdown.
  The vector contract is now the dependency-free, deterministic `stdlib-hash-ngram-v1`; arbitrary
  learned-semantic recall is explicitly not claimed. No specialist manifests are installed in core,
  so implementation phases use the generic delegation briefs already recorded above.
