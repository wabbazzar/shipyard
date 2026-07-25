# Dedupe collectors.sh medic_incidents by incident, not by lifecycle event

- **Status:** draft — ready for `polish-ticket`
- **Priority:** medium
- **Type:** bugfix
- **Estimated Points:** 2 (single phase)
- **Approved:** Wesley via Daily Dispatch — proposal `mentat:shipyard:5e938498`

## Summary

`agents/design/collectors.sh` counts `medic_incidents` by counting **every**
`medic.*incident*` lifecycle event, so a single incident that emits 4–5
lifecycle events (`detected`/`classified`/`incident`/`frozen`) is counted 4–5
times. The nightly telemetry handed to the design (mentat) role reports
`medic_incidents=99` against `job_fail=2` — a false crisis. Fix the count to
dedupe by distinct `incident_id`.

## Problem / Background — the captured reproduction (acceptance anchor)

**Production signature (2026-07-24 → 2026-07-25, this repo's own crew).** The
mentat proposal that spawned this ticket cites its own telemetry input:
`medic_incidents=99 vs job_fail=2`, while the 3 verbatim
`medic_incident_examples` in the same summary cover only **2 distinct
`incident_id`s** (`9da68ea4f6…` appears twice via separate lifecycle events,
`fcb39cb43…` once).

**Root cause — `agents/design/collectors.sh:97-98`:**

```jq
medic_incidents: [.[] | select((.event // "") | startswith("medic."))
                       | select((.event // "") | contains("incident"))] | length,
```

This counts one array element per **event**. The medic runner
(`agents/medic/runner.sh`) emits up to 4–5 `medic.*incident*` events per single
incident — verified against the live event stream, where one `shredly-suk`
incident on 2026-07-25 produced `medic.incident.detected`,
`medic.incident.classified`, `medic.incident`, and `medic.incident.frozen`, all
carrying the **same** `incident_id`
(`c96543e17b46…`). So the count scales with the medic's tracing verbosity, not
with the number of incidents.

**`incident_id` presence — verified.** Every `medic.*incident*` event in the
current format carries a non-null `incident_id` (checked against both
`~/code/wabbazzar-ice/data/events/2026-07-25.jsonl` and `2026-07-24.jsonl`).
Deduping by `incident_id` is therefore well-defined for all current events.

**Why not caught.** The only test that asserts `medic_incidents`
(`tests/design.bats:101`, `= "1"`) is fed by `plant_telemetry`
(`tests/design.bats:38-55`), which plants exactly **one** medic event
(`medic.incident.opened`, line 44) with **no `incident_id`**. With a single
event the buggy per-event count and a correct per-incident count are
indistinguishable (both `1`), so the multi-event inflation was never exercised.
The fixture never plants two-or-more lifecycle events for one incident.

## Technical Requirements

- **Modify — `agents/design/collectors.sh:97-98` ONLY.** Change the
  `medic_incidents` jq expression to count **distinct `incident_id`s** among the
  `medic.*incident*` event set, instead of counting every event:

  ```jq
  medic_incidents: ([.[] | select((.event // "") | startswith("medic."))
                          | select((.event // "") | contains("incident"))
                          | .incident_id | select(. != null)] | unique | length),
  ```

  (Exact jq form is polish/execute's to finalize; the contract is
  *distinct-incident count*, not event count.) See **Decision D-1** for how
  events lacking an `incident_id` are handled.
- **Out of scope — do not touch:**
  - `agents/medic/runner.sh`'s multi-event emission — emitting
    `detected`/`classified`/`incident`/`frozen` per incident is **intentional**
    for tracing; the fix is on the *consumer* side, not the emitter.
  - The separate tmp/-file-based `.sources.medic_incidents` field written by
    `runner.sh` — unrelated path, already incident-scoped.
  - The `medic_incident_examples` block (`collectors.sh:102-107`) — it already
    prefers the consolidated `medic.incident` event and is correct; leave it.
  - Every other count in `events_summary` (`job_ok`, `job_fail`,
    `release_findings`, `examples`).

## Implementation Plan

Single phase — a one-expression consumer-side fix plus its regression test.
Disjoint from any runner; `collectors.sh` is read-only telemetry, so no unit
re-bake and no fleet-live mutation risk.

### Phase 1 — dedupe the count + regression test (2 pts)
- Rewrite `collectors.sh:97-98` to the distinct-`incident_id` count above.
- **Regression test.** Upgrade the existing coverage so it actually exercises
  multi-event inflation (default, D-2): extend `plant_telemetry`
  (`tests/design.bats:38-55`) so the medic telemetry plants **multiple lifecycle
  events for one incident sharing a single `incident_id`** — e.g.
  `medic.incident.detected` + `medic.incident.classified` + `medic.incident` +
  `medic.incident.frozen`, all with `incident_id":"inc_aaa"`. The existing
  assertion `medic_incidents == "1"` (`design.bats:101`) then becomes the
  regression: it stays `1` under the fix and reads `4` (event count) against
  pre-change code. Show it **failing red** against the unpatched
  `collectors.sh` first (house rule).
- Gate class: **Shell scripts** (`bash -n agents/design/collectors.sh`) and
  **Test suite** (`bats tests/design.bats`, then the full `bats tests/`).
- No deck/skill frontmatter touched → `check-deck-fresh.sh` expected unchanged;
  no `install.sh` env knob → no README table change.

## Testing Strategy

- **Regression (P1):** `tests/design.bats` "collectors count events…" — with the
  upgraded `plant_telemetry`, assert `medic_incidents == 1` from ≥4 planted
  lifecycle events of one incident. Hermetic (planted files, PATH shim; no
  network/model). Must fail red (`= 4`) on pre-change code.
- **Full suite:** `bats tests/` (baseline **273 `@test` blocks across 31 files**;
  confirm current green count at build time — CLAUDE.md's "138" is stale).
- **Leak firewall:** `bash scripts/leak-check.sh`.
- **Deck freshness:** `bash scripts/check-deck-fresh.sh` (expected: unchanged).
- **Syntax:** `bash -n agents/design/collectors.sh`.

## Acceptance Criteria / Definition of Done

- [ ] `collectors.sh` `medic_incidents` counts **distinct `incident_id`s**, not
      lifecycle events — a single incident emitting `detected`+`classified`+
      `incident`+`frozen` counts **1**.
- [ ] `plant_telemetry` plants ≥4 lifecycle events for one incident (shared
      `incident_id`); `design.bats` asserts `medic_incidents == 1`.
- [ ] That assertion was shown **failing red** (`= 4`) against pre-change
      `collectors.sh` before the fix landed.
- [ ] `medic_incident_examples` output is unchanged (still the last ≤3
      consolidated `medic.incident` events).
- [ ] No other `events_summary` count changed; `agents/medic/runner.sh`
      untouched.
- [ ] `bats tests/` green; `leak-check.sh`, `check-deck-fresh.sh`, and
      `bash -n agents/design/collectors.sh` all green; worktree clean.

## Dependencies

None.

## Risks & Mitigations

- **Risk: events lacking `incident_id` silently drop from the count.**
  Mitigation: current-format events all carry `incident_id` (verified);
  collectors reads a recent `--days` window where pre-upgrade id-less events
  won't appear. Behavior for id-less events is pinned by **D-1** and covered by
  a test if the fallback branch is chosen.
- **Risk: fleet-wide consumer change.** `collectors.sh` runs for every project's
  design role. Mitigation: it is **read-only** telemetry (no commits, no
  mutations); the change only corrects a displayed number and can only *lower* an
  inflated count. No config key, no unit re-bake.
- **Risk: the fix over-narrows to `.event=="medic.incident"` and undercounts
  pre-upgrade incidents that never emitted the consolidated event.** Mitigation:
  D-1 default is dedupe-by-`incident_id` (counts any incident that emitted *any*
  id-bearing lifecycle event), which is strictly more robust than the
  consolidated-only alternative.

## Out of scope

- Changing `agents/medic/runner.sh`'s per-incident multi-event emission.
- The tmp/-file-based `.sources.medic_incidents` field in `runner.sh`.
- Reworking `medic_incident_examples` or any other `events_summary` field.
- Any change to how incidents are *detected* or *notified* — this is purely how
  they are *counted* for the design summary.

## Decisions (default-and-record — veto at review)

| # | Decision | Locked default | Why |
|---|---|---|---|
| D-1 | How to count `medic.*incident*` events with **no** `incident_id` | **Exclude them** — count distinct non-null `incident_id`s | Current-format events always carry `incident_id`; the recent-window read makes id-less (pre-upgrade) events a non-issue. Veto → include id-less events by falling back to counting `.event=="medic.incident"` when no ids are present, or key on `.incident_id // .ts`. |
| D-2 | Regression-test placement | **Upgrade `plant_telemetry`** so the existing `design.bats:101` assertion becomes the regression | Minimal surface; the 6 `plant_telemetry` callers only assert the count in one test, and reusing it turns a latent gap into a live guard. Veto → add a standalone fixture + dedicated `@test` and leave `plant_telemetry` as-is. |
