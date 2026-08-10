# Classify weekly Claude-limit incidents without standard escalation

- **Created:** 2026-08-10
- **Owner:** wabbazzar
- **Status:** Pending
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

Delegation: subagent — own the helper, runner, role contract, and focused medic
fixtures; return failing-first output, exact side-effect counts, and focused
gate results in no more than 40 lines.

### Phase 2 — project opt-in and canonical documentation (2 pts)

- Enable `weekly_limit_classification = true` for Shipyard.
- Update the existing README medic/notification documentation with the config
  boundary and no-escalation semantics; do not add a parallel explainer.
- Run the complete repository gates and inspect the fixture event/result
  artifacts for consistent `rate_limit`/`skip` state and absence of outward
  effects.
- Verification class: full Bats, syntax, leak, deck freshness/completeness,
  ticket lifecycle, delegation report, and clean Git state.

Delegation: subagent — review the opt-in/docs/test delta against the ticket and
return only drift findings plus exact gate evidence in no more than 40 lines.

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

---

Draft ready for `polish-ticket`.
