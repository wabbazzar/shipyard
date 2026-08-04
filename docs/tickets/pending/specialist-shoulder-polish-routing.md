# Make specialists real polish and shoulder reviewers across Claude and Codex

- **Created:** 2026-08-04
- **Owner:** wabbazzar
- **Status:** Draft — ready for polish
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 18 (5 phases, cap 5/phase)

## Summary

Turn Shipyard's specialist archetype from a decision-log scaffold plus generic release reminder into
an actually invoked reviewer. A project-installed specialist must participate in ticket polishing
and hunk-keyed shoulder review for both Claude and Codex, while retaining the cold-context release
critic and preserving existing single-harness installs.

## Problem / background

`skills/shipyard/shipyard.sh:392-502` currently creates a decision log, one
`.claude/agents/<subsystem>-specialist.md`, a consult note in `.agents/gates.md`, a hunk-keyed
convention in `.agents/release.md`, and a write-ticket context entry. It does not create a specialist
runner or cause the specialist to run.

`agents/release/critic-watch.sh:35-40,649-693` always builds one prompt from the generic release
critic. The critic intentionally has no author transcript (`agents/release/critic-role.md:25-29`)
and ignores queued paths outside the watched project, so it cannot detect either an author's intent
to open an Infrastructure/Platform PR or edits made later in a sibling checkout. The workflow must
therefore catch outward infrastructure work at ticket/polish preflight and review matching local
hunks over shoulder; it must not claim that diff review can read thoughts.

The installer also selects one scalar authoring harness (`install.sh:215-234,1631-1693`). Claude
and Codex queue implementations share a format, but a local installation cannot declaratively wire
and verify both. Judgify currently uses Codex capture only; Claude sessions can therefore miss the
same review.

This gap allowed a plausible but false AWS model to survive mocked tests, repeated canaries, and a
request to modify the central Infrastructure repository. A specialist should have required current
primary documentation, separated source and destination KMS permissions, challenged the ambiguous
EC2 error, and blocked external escalation until the local permission matrix was actually tested.

## Confirmed assumptions

- Specialists are knowledge-bearing reviewers, not builders or redesigners
  (`agents/specialist/role.md:1-14`).
- Shoulder review remains hunk-keyed and cold-context; a changed-file name without real hunks cannot
  trigger a blocking finding (`agents/release/critic-role.md:31-55`).
- Ticket polish already knows to name an installed specialist in delegation briefs, but there is no
  executable invocation contract (`skills/polish-ticket/SKILL.md`, checklist B).
- AWS, Terraform, and Endor expose maintained live documentation. Wiz evidence may require an
  authenticated tenant; absence of accessible official evidence must remain explicit rather than
  being filled with remembered remediation text.

## Objective

For any installed specialist, Shipyard deterministically invokes that specialist during applicable
ticket polish and matching hunk review, delivers its findings to the active Claude or Codex author,
and records enough source/fetch evidence to distinguish current vendor documentation from project
memory.

## Technical requirements

### Specialist manifest and source contract

- Add a machine-readable project manifest per specialist under a neutral `.agents/` path. It names:
  specialist slug, common prompt/agent definition, decision log, hunk path patterns, ticket semantic
  triggers, external-repository escalation triggers, and live documentation sources.
- The existing `.claude/agents/<slug>-specialist.md` remains a supported human/Claude discovery
  surface, but the executable reviewer must read the neutral manifest and common specialist role so
  Codex does not depend on Claude-only discovery.
- Live documentation entries store only label, canonical URL or live index, authority, and required
  access mode. They never vendor or snapshot provider prose. Each review records the URL, retrieval
  time, success/failure, and the exact claim supported. Failed retrieval yields `unverified` or a
  blocking evidence gap according to the specialist's rubric; it never falls back to model memory.
- The scaffolder remains deterministic and makes no model/network call.

### Polish routing

- `polish-ticket` must invoke applicable specialists when ticket text or named files match their
  manifest triggers. The returned verdict becomes a cited ticket decision/gate, not an invisible
  suggestion.
- A ticket proposing work in a configured external Infrastructure/Platform repository is a blocking
  escalation until the specialist records that current primary docs, live read-only state, existing
  organization patterns, local IAM/resource behavior, and narrower local fixes were checked.
- The specialist may return `block`, `warn`, `note`, or clean using the existing finding vocabulary.
  It reviews and updates its decision log; it never edits product code or creates the external PR.

### Shoulder routing

- Keep the generic release critic unchanged as the first cold review.
- For a queued batch with real hunks matching a specialist manifest, run a second specialist review
  with the common specialist role, project block, decision log, gates, exact queued hunks, and live
  source registry. Merge/dedupe its findings into the existing delivery and stop-gate surfaces.
- Mere changed-file membership, a reverted edit, or an unmatched hunk must not invoke the specialist.
- Ticket-document hunks containing a configured external-repository escalation trigger are eligible
  even before sibling-repo code exists. Do not claim coverage for unrecorded author thoughts or an
  out-of-workflow direct external mutation.

### Claude and Codex capture

- Preserve the scalar `[shoulder].harness` behavior byte-for-byte when no new configuration is set.
- Add an explicit multi-author configuration that can wire Claude and Codex capture concurrently to
  the same project while retaining per-session author identity for correct finding delivery.
- Hooks remain additive, project-scoped, private, non-blocking during edit capture, and loaded only
  at session start. Doctor reports each configured author independently.
- A deterministic harness matrix must prove Claude edit capture, Codex `apply_patch` capture,
  specialist trigger/no-trigger behavior, and delivery routing without calling a model or network.

## Implementation plan

### Phase 1 — manifest and deterministic scaffold (points: 3)

- Extend `add-specialist` to create and validate the neutral manifest and a shared prompt pointer.
- Add manifest parsing/validation helpers with fail-closed path containment and no command
  evaluation.
- Preserve idempotence and every current artifact.

Delegation: subagent — implement the manifest/scaffold slice and return ≤40 lines: files changed;
commands and exit codes; new fixture paths; blockers.

Gate classes: shell behavior, scaffold contracts, leak/deck freshness.

### Phase 2 — specialist shoulder execution (points: 5)

- Select specialists from real queued hunks and build bounded specialist prompts.
- Run the generic critic plus applicable specialist reviewers; normalize and merge findings.
- Make retrieval evidence explicit and keep live-document access read-only.

Delegation: subagent — own watcher/prompt selection and tests; return ≤40 lines with exact trigger,
no-trigger, malformed-manifest, and finding-merge evidence.

Gate classes: shell, shoulder queue/watcher, malformed-input safety, no-model unit fixtures.

### Phase 3 — polish invocation and infrastructure escalation gate (points: 3)

- Add a deterministic specialist-discovery/invocation contract to `polish-ticket` and its tests.
- Require an evidence-bearing specialist verdict before any configured external Infrastructure or
  Platform PR phase can become executable.
- Preserve projects with no specialists.

Delegation: subagent — implement skill contracts and content/behavior tests; return ≤40 lines with
failing-before/passing-after evidence and exact one-line prose assertions.

Gate classes: skill content contracts, ticket-pipeline tests, leak/deck freshness.

### Phase 4 — dual Claude/Codex author wiring (points: 5)

- Add backward-compatible multi-author config, author-aware queue identity, installer wiring,
  delivery, rollback, and doctor diagnostics.
- Prove both hooks coexist without duplicate or cross-session delivery.

Delegation: subagent — own installer/queue/delivery changes and the cross-harness fixture matrix;
return ≤40 lines with commands, exit codes, queue names, and doctor evidence.

Gate classes: shell, installer invariance, Claude/Codex shoulder fixtures, launchd/systemd templates.

### Phase 5 — end-to-end fixture install and documentation (points: 2)

- Install a fixture security/infrastructure specialist with AWS/Terraform/Endor/Wiz live-source
  entries and an external-PR escalation trigger.
- Exercise polish trigger, Claude hunk trigger, Codex hunk trigger, unmatched hunk, inaccessible Wiz
  source, and clean delivery entirely in isolated fixtures.
- Document the honest coverage boundary and local-project adoption steps.

Delegation: subagent — build the fixture and docs; return ≤40 lines with each matrix verdict and no
network/model invocation evidence.

Gate classes: full bats suite, syntax, leak check, deck freshness, doctor.

Every delegated phase carries this clause:

> Converge honestly or report the precise blocker with the actual evidence — NEVER fake green,
> weaken a check, or hand-wave "should work". Run the real command, read the real file, and report
> exact output and exit codes, not adjectives. If it needs spend, an outward-facing action, or a
> destructive change, stop and report instead.

## Testing strategy

- Add failing-first Bats coverage beside `tests/shipyard-add-specialist.bats` and the existing
  shoulder/install suites.
- Stub model launch and live-document fetch in deterministic tests; assert the exact prompt inputs,
  retrieval ledger, and findings rather than making network/model calls.
- Run `bash -n` on every touched shell script, then the focused Bats files and full `bats tests/`.
- Run `bash scripts/leak-check.sh`, `bash scripts/check-deck-fresh.sh`, and
  `./install.sh --doctor --project <fixture>` where the phase applies.
- Prove legacy single-harness and no-specialist fixtures are unchanged.

## Definition of Done

- [ ] A matching real hunk causes the installed specialist—not only the generic critic—to review
      and return a finding through the normal shoulder delivery path.
- [ ] An unmatched or reverted hunk does not invoke the specialist.
- [ ] Applicable tickets invoke the specialist during polish and cannot authorize a configured
      Infrastructure/Platform PR without its evidence-bearing verdict.
- [ ] One local installation can capture and correctly deliver reviews to concurrent Claude and
      Codex author sessions; the legacy scalar configuration is unchanged.
- [ ] Specialist reviews fetch or attempt current canonical documentation and record URL/time/status;
      no vendor prose snapshot is installed.
- [ ] Inaccessible Wiz documentation remains explicitly unverified and cannot be silently replaced
      with remembered remediation.
- [ ] The full Bats suite, shell syntax, leak check, deck freshness, and doctor gates are green.

## Boundaries

### Always

- Keep specialists review-only, evidence-citing, and hunk-keyed over shoulder.
- Preserve the generic release critic and backward compatibility for projects without specialists.
- Use primary live vendor documentation and live/internal implementation evidence.

### Ask first

- Any network fetch that needs a new credential or paid service.
- Any mutation to a user's global Claude/Codex configuration beyond the explicitly requested
  additive `--wire-shoulder` install path.
- Any merge to Shipyard main, because that dev clone is fleet-live at the next timer fire.

### Never

- Never snapshot AWS, Terraform, Endor, Wiz, or other vendor documentation into Shipyard.
- Never let a specialist write product code, redesign the subsystem, create an external PR, or
  mutate cloud state.
- Never replace the generic release critic with a security-specific monolith or introduce a new
  top-level service/dependency for specialist routing.
- Never claim that a diff-only reviewer can inspect unrecorded chain-of-thought or edits outside its
  project boundary.

## Dependencies

- Existing specialist archetype and shoulder watcher.
- Local Judgify adoption follows this core ticket and is tracked separately in Judgify.

## Risks and mitigations

- **Review latency/cost:** invoke specialists only on real matching hunks and bound prompt/evidence.
- **Duplicate findings:** normalize and dedupe generic/specialist results before delivery.
- **Cross-harness misdelivery:** carry author harness identity in queue/session metadata and test
  concurrent sessions.
- **Stale documentation:** store links and retrieval evidence, never copied prose; fail explicitly
  when current evidence is unavailable.
- **False confidence about intent:** catch external work in ticket polish and document that direct
  out-of-workflow mutations remain outside shoulder coverage.

## Out of scope

- Replacing vendor security scanners or certifying cloud compliance.
- Giving the specialist cloud-write, GitHub-write, or merge authority.
- Making arbitrary sibling-repository hunks visible to a project watcher without their own install.
- Implementing the Judgify-specific specialist contents or the T48 KMS correction in Shipyard core.

## Ledger

Empty — populated by `execute-ticket` phase by phase after polish.

