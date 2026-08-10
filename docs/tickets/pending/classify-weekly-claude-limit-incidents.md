# Classify weekly Claude-limit incidents without standard escalation

- **Created:** 2026-08-10
- **Owner:** wabbazzar
- **Status:** Pending — polished; no open decisions
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 5 (two phases: 3 · 2)
- **Refs:** approved Daily Dispatch item `mentat:shipyard:9fc1a6e9`;
  `agents/medic/runner.sh:878-915`, `agents/medic/runner.sh:981-1033`,
  `agents/medic/role.md:135-151`, `.agents/config.toml:63-68`,
  `tests/incident-reroute.bats:15-105`

## Summary

Recognize the proven Claude weekly-usage-limit signature during medic incident
classification, label the incident `rate_limit`, retain ordinary incident
telemetry, and bypass the standard owner-escalation path. Preserve the current
path byte-for-byte when the new project config key is unset and preserve all
existing escalation behavior for non-matching incidents.

## Objective

With `[medic].weekly_limit_classification = true`, any classified incident
whose bounded summary/hypothesis contains the normalized tokens `Claude`,
`weekly`, and `limit` is deterministically rewritten to class `rate_limit` and
action `skip` before action dispatch. The runner records the classification
and a no-escalation action, but emits no owner notification, cooldown/freeze,
daily-escalation increment, or incident-repair proposal. A non-match follows
the existing class and action without change.

## Problem / background

Two real fleet incidents on 2026-07-28 describe the same external condition
with different wording: one says “Claude weekly-limit outage” and the other
says “weekly Claude usage limit.” The current model-owned classifier has no
`rate_limit` enum (`agents/medic/role.md:135-151`). Its `infra` and `cap_hit`
classes enter the standard actionable-notification and 24-hour freeze path
(`agents/medic/runner.sh:1023-1033`), so a known self-resolving account limit
looks like an ordinary operator-actionable infrastructure incident.

The approved Dispatch item requires a distinct classification and bypass of
standard escalation. It explicitly excludes changing rate-limit behavior,
retry, or backoff. Existing release-side usage-cap handling remains the source
of the underlying incomplete result; this ticket changes only how medic routes
the resulting classified incident.

## Confirmed assumptions and decisions

| Decision | Locked result |
|---|---|
| Match grammar | Lowercase and normalize punctuation/hyphenation, then require all three bounded tokens `claude`, `weekly`, and `limit` in either order. Do not match a generic weekly limit that does not name Claude. |
| Classification | Matching model output becomes `class=rate_limit`, `action=skip` before the existing per-class action switch. |
| Observable record | Continue emitting `medic.incident.detected`, `medic.incident.classified`, and the consolidated incident detail; record the action outcome as `rate_limit`. |
| Escalation | `rate_limit` does not call `quartet_notify`, freeze/cool down, increment the daily escalation count, create a design proposal, invoke build, retry, or restart. |
| Compatibility | New behavior is gated by `[medic].weekly_limit_classification`; unset/false preserves the current classified JSON and dispatch path exactly. Shipyard opts in explicitly in `.agents/config.toml`. |
| Text surface | Inspect only bounded `incident_summary` and `hypothesis` strings already returned for the classified incident. Do not scan arbitrary logs, prompts, or files in the action loop. |
| Documentation | Add `rate_limit`/`skip` to the generic medic role contract and document the opt-in classification in the existing README medic section. |

There are no open product decisions. Wesley's approved acceptance requires
both the distinct category and the standard-escalation bypass.

### Open decisions with defaults

None.

### User-decision class

None. The tracked Shipyard opt-in changes a live automation route, but Wesley
explicitly approved this exact category-plus-bypass behavior through Daily
Dispatch on 2026-08-10. Publication still stops at a green PR because
`[medic].can_merge=false`; the builder may not merge it.

**Auto-gate: PROCEED.**

## Orchestration protocol

The builder is the orchestrator. Delegate each implementation/review slice,
keep every return at or below 40 lines, and personally rerun every named gate
before every commit. Work only in this canonical checkout on local `main`, in
small verified commits; do not create or switch to a local branch/worktree.
Before each edit and commit, run `git status --short --branch` and
`git log --oneline -3`. If another session changed the head or overlapping
files, stop staging and reconcile without reset, rebase, force-push, or lost
history. Scope every `git add` to this ticket's files; never use `git add -A`.

Because `agents/lib/**` and `agents/medic/runner.sh` are fleet-live from this
checkout, no phase may leave syntax or focused behavior red between commits.
Do not start `shipyard-suk.service` as a feature gate: that would invoke the
real classifier and could notify. Prove the action boundary hermetically; after
publication, the next ordinary timer run loads the merged source.

For every delegated slice:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

## Verified polishing baseline — 2026-08-10 CDT

| Surface | Evidence | Consequence |
|---|---|---|
| Repository | Draft commit `b0146ca` is the only local commit above clean `origin/main` `73163de`; no unrelated worktree dirt was present before drafting. | Continue on canonical local `main`; push the final exact head to a remote PR branch without switching locally. |
| Real incidents | Fleet JSONL lines from 2026-07-28 contain the two phrases “Claude weekly-limit outage” and “weekly Claude usage limit”; punctuation/order differs but all three bounded tokens are present. | The RED/GREEN fixture needs both variants and must not use a single literal sentence matcher. |
| Current action path | `agents/medic/runner.sh:1005-1033` emits classification, then notifies/freezes `infra`/`cap_hit`; `agents/medic/role.md:143-151` has no `rate_limit`/`skip`. | Override and persist the class before event/action dispatch; add a side-effect-free case arm. |
| Toolchain | `bats --version` → `Bats 1.10.0`; `bats --count tests/` → 808; the pre-change regression-reroute guard passed 1/1. Syntax, Python compile, leak, deck freshness/completeness, and diff checks passed. | Exact focused/full commands below exist on this host. Preserve the pre-change guard as proof non-matching escalation remains real. |
| Live timer | `shipyard-suk.timer` runs every ten minutes and its service executes `/bin/bash …/agents/medic/runner.sh --project …/shipyard --mode scan` directly from this checkout. | A committed source edit is fleet-live on the next run; keep every phase green and never manually trigger a billable classifier for verification. |
| Specialists | `find .agents/specialists -name '*.toml'` returned no manifests. | No specialist review applies. |
| Capability | `.agents/config.toml:52-68` permits PR proposals but keeps `allow_no_ci=false` and `can_merge=false`. | Open a PR only after local gates; require green CI and stop for the human merge stamp. |

## Technical requirements

- Add one deterministic, sourceable helper under `agents/lib/` for normalized
  token classification. It accepts bounded text, returns a load-bearing status,
  and uses only the repository's existing shell/Python/jq toolchain.
- Source the helper from `agents/medic/runner.sh` and apply it to each model-
  classified incident before `medic.incident.classified` is emitted at
  `agents/medic/runner.sh:1005-1008` and before dispatch begins at `:1018`.
- When enabled and matched, update the in-memory incident and the persisted
  result document consistently so the final result, action ledger, and event
  stream all say `rate_limit`/`skip`; do not leave a contradictory original
  `infra` or `regression` in `medic-result.json`.
- Add an explicit `rate_limit` case beside `duplicate` at
  `agents/medic/runner.sh:1018-1021` that records a skip outcome and performs no
  outward or state-mutating action.
- Extend the generic enum/action schema at `agents/medic/role.md:143-151` so a
  model may also produce the correct class directly; the deterministic runner
  override remains authoritative for proven matches.
- Add the opt-in to this project's `[medic]` block at
  `.agents/config.toml:63-68`; no unit environment change is needed because the
  runner already reads project TOML into `CFG_JSON`.
- Keep event content bounded and existing incident IDs unchanged. Do not emit
  the raw prompt, result body, or filesystem paths.

## Implementation plan

### Phase 1 — deterministic classification and dispatch (3 pts)

- Add failing-first hermetic Bats cases using the existing medic scan fixture:
  both observed wording variants must currently follow standard escalation,
  then pass as `rate_limit` with zero notification/freeze/proposal/build calls.
- Add the `agents/lib/` matcher and wire the config-gated override into
  `agents/medic/runner.sh` before telemetry and action dispatch.
- Add a non-match and unset/false compatibility matrix proving ordinary
  `infra` and `regression` routing is unchanged.
- Update the role enum and action grammar without changing model invocation,
  token accounting, retry, timeout, or backoff.
- Verification class: focused Bats, shell syntax, public-repo hygiene, diff.

Delegation: subagent — starting from this polished ticket and `b0146ca`, own
only `agents/lib/incident-classification.sh`, `agents/medic/runner.sh`,
`agents/medic/role.md`, and the focused medic Bats file. First add the named
fixture and run it against unchanged runtime code to record the real RED. Then
implement the helper/override/case arm and compatibility matrix. Do not edit
config/docs, run a real model, invoke systemd, or notify. Return ≤40 lines:
files changed; RED and GREEN commands with exit codes/test counts; exact
result/event/action/notify/cooldown/proposal/build assertions; blockers. Apply
the anti-cheating clause in the Orchestration protocol verbatim.

**Phase 1 verification surface:**

```bash
git status --short --branch
git log --oneline -3
bash -n agents/lib/incident-classification.sh agents/medic/runner.sh
bats --filter 'weekly Claude limit' tests/medic-rate-limit-classification.bats
bats --filter 'reroute: regression-class incident -> proposal' tests/incident-reroute.bats
bats --filter 'medic gate: over-cap own-svc tokens|an unrelated no-result failure retains normal medic escalation' tests/token-caps.bats tests/release-stall-retry.bats
git add -N tests/medic-rate-limit-classification.bats agents/lib/incident-classification.sh
bash scripts/leak-check.sh
git diff --check
python3 scripts/delegation-report.py
```

Observable Phase 1 DoD: the RED ledger names the pre-change notify/freeze or
proposal side effect; GREEN reports both match variants as persisted/evented
`rate_limit` + `skip`, zero outward/stateful effects, and unchanged explicit-
false/unset plus non-match paths.

### Phase 2 — project opt-in and canonical documentation (2 pts)

- Enable `weekly_limit_classification = true` for Shipyard.
- Update the existing README medic/notification documentation with the config
  boundary and no-escalation semantics; do not add a parallel explainer.
- Run the complete repository gates and inspect the fixture event/result
  artifacts for consistent `rate_limit`/`skip` state and absence of outward
  effects.
- Verification class: full Bats, syntax, leak, deck freshness/completeness,
  ticket lifecycle, delegation report, and clean Git state.

Delegation: subagent — cold-review the complete Phase 1 diff, then own only
`.agents/config.toml` and `README.md`. Confirm the opt-in is under `[medic]`,
the README edits the existing medic/notification contract, and no unit/env,
retry/backoff, or unrelated class behavior changed. Return ≤40 lines: files
changed; review findings; exact commands/exit codes/test counts; the config and
README lines proving the boundary; blockers. Apply the anti-cheating clause in
the Orchestration protocol verbatim.

**Phase 2 verification surface:**

```bash
git status --short --branch
git log --oneline -3
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bats tests/
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs  # exit 0, or documented exit 3 only when Playwright is absent
bash scripts/ticket-lifecycle.sh --project . --check
python3 scripts/delegation-report.py
git diff --check
find .. -path '*/.claude/skills/*' -type l -lname '*worktrees*' -print | wc -l  # must print 0
```

After those pass, keep this acceptance evidence in its own commits. The
separately approved proctor-battery ticket is serialized immediately afterward
on the same canonical local `main`; publish the exact cumulative head for both
tickets without switching this checkout:

```bash
git fetch origin main
git status --short --branch
git log --oneline origin/main..HEAD
git push origin HEAD:refs/heads/feature/dispatch-release-medic-hardening
gh pr create --repo wabbazzar/shipyard --base main \
  --head feature/dispatch-release-medic-hardening \
  --title "Harden medic rate limits and proctor battery ownership" \
  --body-file <prepared-body>
gh pr checks <number> --repo wabbazzar/shipyard --watch --interval 10
```

Do not merge. When all required checks are green, send exactly one PR-ready
owner alert through the configured `$QUARTET_NOTIFY_CMD`, record its result,
and stop for the human merge stamp. If GitHub is unavailable, record the exact
external state and leave the phase pending; never treat missing CI as green.

Observable Phase 2 DoD: 808-or-later full Bats count is green, all canonical
gates pass, the PR exact head matches local HEAD, all required CI conclusions
are success, and no worktree-linked skill symlink exists.

## Testing strategy

- Add focused hermetic coverage to the canonical medic scan harness in
  `tests/incident-reroute.bats` or a narrowly named sibling Bats file. Use
  `tests/helpers.bash` stubs only; no test reaches a model, network, GitHub, or
  real notification transport.
- Show the focused test RED against pre-change `main`: the proven signature is
  still notified/frozen or rerouted rather than classified `rate_limit`.
- Assert both true variants, non-match, explicit false, and unset behavior.
- Assert the persisted result JSON, `medic.incident.classified`, consolidated
  action outcome, notification log, cooldown state, proposal file, build call,
  and escalation counter—not only a helper return value.
- Run `bats tests/`, `bash scripts/leak-check.sh`, and
  `bash scripts/check-deck-fresh.sh` before completion, plus the applicable
  syntax and lifecycle gates from `.agents/gates.md`.

## Definition of Done

- [ ] A failing-first hermetic fixture captures standard escalation for the proven weekly-Claude-limit signature on pre-change `main`.
- [ ] Both observed wording variants classify as `rate_limit` with action `skip` when the config key is true.
- [ ] Matching incidents emit consistent detected/classified/detail telemetry and persist `rate_limit`/`skip` in the final medic result.
- [ ] A matching incident produces zero owner notifications, freezes/cooldowns, escalation-cap increments, incident-repair proposals, build calls, retries, and restarts.
- [ ] A generic weekly limit without `Claude` does not match.
- [ ] Non-matching `infra` and `regression` incidents retain their existing actions and escalation behavior.
- [ ] Unset and explicit-false configuration preserve today's result/event/action behavior.
- [ ] The generic medic role and existing README document the class, action, config key, and scope boundary.
- [ ] Focused tests, full Bats, shell syntax, leak, deck freshness/completeness, lifecycle, delegation, and diff gates pass.
- [ ] Each phase is a small verified commit on canonical local `main`; the final exact head is published through a green PR without a local branch/worktree or self-merge.

## Boundaries

### Always

- Preserve stable incident IDs and content-safe incident telemetry.
- Keep the override deterministic, config-gated, and covered at the observable
  action/result/event boundary.

### Ask first

- Widening detection beyond the proven Claude weekly-limit token family.
- Turning the behavior on by default for every existing project.

### Never

- Change rate-limit enforcement, reset timing, retry/backoff, model/provider
  selection, notification transport, or release-runner usage-cap handling.
- Add a new top-level dependency, second medic pipeline, arbitrary log scanner,
  or model call.

## Dependencies

- Existing classified-incident action loop and event helpers in
  `agents/medic/runner.sh`.
- Existing hermetic medic fixtures and notification stubs.
- Human approval recorded for `mentat:shipyard:9fc1a6e9`.

## Risks and mitigations

- **False suppression:** require all three bounded tokens and retain explicit
  non-match tests; do not match generic `weekly limit` text.
- **Contradictory evidence:** rewrite the persisted incident object before
  telemetry/action dispatch and assert result/event/action parity.
- **Hidden behavior change for the fleet:** default the config key false and
  prove unset/false compatibility before opting Shipyard in explicitly.
- **Notification leakage through a sibling arm:** assert all outward/stateful
  side effects at the scan boundary, not only the selected case label.

## Out of scope

- Changing how release detects or reports account usage caps.
- Retrying, delaying, restarting, or otherwise mitigating a rate limit.
- Reclassifying other quota, API 429, token-budget, provider, or billing
  failures without separately approved evidence.
- Reworking notification policy or medic cooldown semantics.

## Ledger

- 2026-08-10 — draft created from approved Daily Dispatch item
  `mentat:shipyard:9fc1a6e9`. Read-only probes confirmed two real wording
  variants, the absent class, current escalation arms, no duplicate ticket,
  and clean `main` at `73163de`. No runtime code, service, model, notification,
  or network state changed during intake.
- 2026-08-10 — polished against current config/gates, canonical source, the
  808-case Bats inventory, live timer wiring, capability settings, and absent
  specialist manifests. Exact RED/GREEN surfaces, bounded delegation briefs,
  fleet-live discipline, and PR-only publication are locked. No runtime code,
  model, notification, service, or remote state changed while polishing.
- 2026-08-10 — execution baseline: `builder: inline (gate commands the
  orchestrator must read itself)`. Full Bats passed 808/808; syntax, Python
  compile, leak, deck freshness/completeness/render, lifecycle, delegation,
  diff, and worktree-link checks passed. Phase 1 plan: `builder: subagent (1
  agent)` owns only the helper, medic runner/role, and focused fixture; it must
  preserve the exact RED before implementing. The orchestrator retains all
  verification, Ledger edits, staging, and commit authority. No live service,
  model, notification, or remote action is part of Phase 1.
- 2026-08-10 — publication route updated: `builder: inline (single-file edit
  in an already-read ticket)`. This ticket and approved item
  `mentat:shipyard:9db7c9ba` retain separate commits and acceptance Ledgers but
  share one cumulative PR from canonical local `main`; no local branch,
  worktree, rebase, or stacked-PR ancestry is introduced.
- 2026-08-10 — Phase 1 implementation: `builder: subagent (1 agent)`. The
  pre-change focused fixture failed 1/1 after recording
  `class=infra action=freeze:infra notify=2 cooldown=infra`; its expected
  `rate_limit` assertion failed. The builder then added the bounded helper,
  config-gated pre-dispatch override, persisted result rewrite, explicit
  side-effect-free action arm, generic role contract, and five-case fixture.
  Root independently verified syntax; new focused Bats 5/5; regression reroute
  1/1; token-cap/no-result compatibility 2/2; leak, diff, and delegation gates
  all exit 0. The two real wording variants now agree across persisted result,
  classified/detail telemetry, and action ledger, with zero notification,
  cooldown/freeze, escalation increment, proposal/build, retry/sleep, or
  restart; generic, false, and unset paths retain standard escalation.

---

Run `execute-ticket` on this decision-complete ticket.
