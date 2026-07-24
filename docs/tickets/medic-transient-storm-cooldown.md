# Medic transient→stuck notify storm — record a cooldown so it alerts once per day

- **Status:** draft (ready for `polish-ticket`; awaiting human stamp)
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 3 (P1 2 · P2 1)

## Summary

The medic scan's `transient`→`stuck` notify path (`agents/medic/runner.sh:1007`)
is the **only** classification that notifies without recording a cooldown. When
a unit stays `failed` across many scan ticks, medic re-detects, re-classifies,
re-retries, and **re-notifies the identical alert every tick** — a notification
storm. Record a cooldown on that path (as every sibling class already does) so a
persistent transient→stuck incident alerts **once per UTC day**, not every tick.

## Problem / Background — the captured reproduction (acceptance anchor)

**Production signature (2026-07-24, this repo's own crew).** `shipyard-suk`
(medic, spacetime theme) runs `runner.sh --project ~/code/shipyard --mode scan`
every 10 minutes. `shipyard-proctor` (release) is a **daily** timer — it ran once
at 04:30, failed (`Claude API stream stalled mid-run … no result.json`), and the
oneshot unit stays in `state=failed` all day. Every 10-minute medic tick from
**05:01 → 07:11** emitted an identical Signal alert:

```
Suk shipyard (transient→stuck)
Retry didn't clear: shipyard-proctor failed: Claude API stream stalled mid-run … retrying.
```

13+ identical messages in ~2h (`bopbop.db`, `role=assistant src=notify`). The
ice event stream confirms the driver: each tick is `medic.job.start →
medic.incident.detected → medic.incident.classified → notify.send`, with **no
`medic.incident.frozen`** for the incident — i.e. no cooldown is ever recorded,
so the next tick re-detects the same id.

**Failing test capturing it** (run against unpatched code, fails red; **not
committed here** — `execute-ticket` adds it at build time as the regression test):

- Stage a `state=failed` systemd unit in `ops.json`; stub `claude` to classify
  it `transient`; stub `systemctl list-units` to keep the unit `failed` on the
  retry recheck (so `still != 0` → the `transient→stuck` branch).
- Run `runner.sh --mode scan` **twice** in the same UTC day (two ticks).
- Assert **exactly one** `transient→stuck` notify across both ticks.
- **Observed on unpatched code: 2 notifies** (verified 2026-07-24 via the
  `incident-reroute.bats` scaffold — `NOTIFYCOUNT=2`, two byte-identical
  `Medic … (transient→stuck) | Retry didn't clear: …` lines). In production this
  is 6/hour for as long as the unit stays failed.

### Root cause (four answers)

- **Where:** `agents/medic/runner.sh:994-1011`, the `transient)` case. On
  `still != 0` it calls `quartet_notify "(transient→stuck)"` + `push_action`
  (1007-1009) but **never `state_set ".cooldowns[$iid]"`**. Every sibling notify
  path *does*: `forbidden|infra|cap_hit` freezes 24h (`:987-988`), `restart`
  freezes one-per-UTC-day (`:1043`), `self_failure` freezes 24h (`:374`). The
  in-code comment at `:1006` even says *"Promote to notify; don't loop again"* —
  the intent is present, the cooldown that enforces it across ticks is missing.
- **When:** long-standing, not a recent regression — `git blame` of the block
  shows only a 2026-07-22 display-name rename (`55ee1ff`) touching the string;
  the missing-cooldown shape predates it. It **manifests** only when a unit
  stays `failed` across many ticks (a daily-timer agent that fails once and stays
  failed all day — exactly `shipyard-proctor`'s shape), which is why it surfaced
  now.
- **Elsewhere:** No — this is the *sole* notify path lacking a cooldown. Grep of
  the `case "$cls"` arms confirms forbidden/infra/cap_hit/restart and the
  `self_failure` guard all set one. Non-goal: changing any of those.
- **Why not caught:** No test runs **two consecutive scans** of the same
  unresolved incident — `incident-reroute.bats` runs `run_medic_scan` once per
  test. The per-tick re-notify (the cross-tick dedup contract) was never pinned.
  Record this in `.agents/gates.md` Traps.

The `stable_id "$kind" "$name" "$DAY"` id (`runner.sh:352`) is **stable within a
UTC day** and the detect loop already skips ids with a live cooldown
(`runner.sh:354-359`). So a single `state_set` on the transient→stuck path is
sufficient — and because the id rolls at UTC midnight, the alert naturally
re-fires once the next day if the unit is still broken (matching `restart`'s
documented one-per-UTC-day policy). No new dedup machinery is needed.

## Technical Requirements

- **Modify:** `agents/medic/runner.sh`, the `transient)` arm's
  `else` (still-failing) branch — currently `runner.sh:1005-1010`. After the
  existing `quartet_notify` + `push_action`, add:
  - `until_ts="$(date -u -d '+24 hours' … )"` (mirror `:987`),
  - `state_set ".cooldowns[\"$iid\"] = {\"frozen_until\":\"$until_ts\",\"reason\":\"transient_stuck\"}"`,
  - `emit medic.incident.frozen "$iid" frozen_until="$until_ts" reason="transient_stuck"`
    (mirror `:989`).
- **State/schema:** none — reuses the existing `cooldowns` map
  (`STATE_FILE=$RESULT_DIR/medic-state.json`, `runner.sh:215`) and the existing
  detect-loop cooldown check (`runner.sh:354-359`). New `reason` value
  `transient_stuck` is free-form.
- **No new unit env knob, no config key** — this restores the documented
  "don't loop again" intent to match the established cooldown contract; the
  unset/default behavior after the fix is "alert once per UTC day," which is the
  intended behavior, not a new capability. (See Decision D-1 to veto.)
- **No model-invocation change** — `token-caps.bats` untouched.

## Implementation Plan

### Phase 1 — Record the cooldown + regression test (2 pts)
- Add the `state_set` cooldown + `medic.incident.frozen` emit to the
  transient→stuck branch (`runner.sh:1007-1009`).
- Add a bats case (the reproduction above) to a medic scan test file
  (mirror `tests/incident-reroute.bats`'s `prep_*` + `run_medic_scan`
  scaffold): two scans, assert exactly one `transient→stuck` notify **and** a
  `cooldowns[<iid>].reason == "transient_stuck"` entry in `medic-state.json`
  after tick 1. Show it failing red against pre-change code first (house rule).
- Gate class: **Shell scripts** (`bash -n` + run) and **Test suite**
  (`bats tests/`).

### Phase 2 — Docs + Traps + full gate sweep (1 pt)
- Record the coverage gap in `.agents/gates.md` Traps appendix ("medic scan:
  every notify path must record a cooldown or it re-alerts every tick; pin
  cross-tick dedup with a two-scan test").
- Run the full gate battery green (see Testing Strategy). No deck/skill
  frontmatter touched, so no `gen-deck-data.py` regen expected — confirm
  `check-deck-fresh.sh` stays clean.

## Testing Strategy

- **Regression (new):** the two-scan bats case — one notify + a
  `transient_stuck` cooldown recorded. Hermetic (PATH shims in
  `tests/helpers.bash`; no network/GitHub/model).
- **Full suite:** `bats tests/` (**verified baseline 2026-07-24: 209 pass, 0
  fail** — `bats tests/ | grep -cE '^ok '`; CLAUDE.md's "138" is stale). Must
  stay green; the new case makes it 210.
- **Leak firewall:** `bash scripts/leak-check.sh`.
- **Deck freshness:** `bash scripts/check-deck-fresh.sh` (expected: unchanged).
- **Syntax:** `bash -n … agents/*/runner.sh …` per the gate file.

## Acceptance Criteria / Definition of Done

- [ ] The captured reproduction (two consecutive scans of the same unresolved
      transient incident) now yields **exactly one** `transient→stuck` notify.
- [ ] After tick 1, `medic-state.json` contains
      `cooldowns[<iid>].reason == "transient_stuck"` with a `frozen_until` ~24h out.
- [ ] A `medic.incident.frozen` event is emitted for the incident on the
      transient→stuck path (parity with forbidden/infra/restart).
- [ ] The next UTC day (new `stable_id`) the alert may fire **once** again if the
      unit is still failed — persistent breakage is not silenced forever.
- [ ] New bats case shown failing against pre-change code, then green.
- [ ] `bats tests/` (139), `leak-check.sh`, `check-deck-fresh.sh`, `bash -n`
      sweep all green.
- [ ] `.agents/gates.md` Traps appendix records the cross-tick dedup gap.
- [ ] No change to any other classification's behavior; `token-caps.bats`
      untouched.

## Polish verification (2026-07-24, this box)

Anchors + toolchain proven during polish so a cold agent can trust them:
- Helpers exist: `state_set()` `runner.sh:241`, `emit()` `:920`, `push_action()`
  `:915`, `quartet_notify()` (used at `:1007`); `STATE_FILE` `:215`.
- Transient→stuck notify is at `runner.sh:1007-1008`; the `# Promote to notify;
  don't loop again.` comment is `:1006`. The sibling cooldown to mirror is
  `:987-989` (`until_ts` + `state_set ".cooldowns[…]"` + `emit medic.incident.frozen`).
- **Gates green now:** `bats tests/` = 209 pass / 0 fail; `leak-check.sh` clean;
  `check-deck-fresh.sh` clean.
- **Repro proven red on unpatched code:** built the two-scan case on the
  `incident-reroute.bats` scaffold → `NOTIFYCOUNT=2` (two identical
  `transient→stuck` notifies). Removed (not committed) — it lands as the
  regression test in Phase 1.

## Ledger

_(builder appends: per-phase plan + commit hash + honest notes on anything deferred)_

- [ ] Phase 1 — cooldown + regression test — commit: ____
- [ ] Phase 2 — Traps note + full gate sweep — commit: ____

## Run it

`execute-ticket docs/tickets/medic-transient-storm-cooldown.md` — **behind the
human gate**; do not build until stamped.

## Dependencies

None. (Independent of why `shipyard-proctor` stalled — that is an infra/API
symptom the medic correctly classifies `transient`; this ticket fixes the
**alerting storm**, not the stall. See Out of scope.)

## Risks & Mitigations

- **Risk: masking a genuinely persistent failure by silencing it.** Mitigation:
  the id rolls at UTC midnight, so a still-broken unit re-alerts once/day —
  same policy `restart` already uses. Not a permanent freeze.
- **Risk: fleet-live blast radius** — `agents/medic/runner.sh` runs for every
  installed project on the next timer fire. Mitigation: the change only *adds* a
  cooldown write on a path that today writes none; it cannot make any project
  notify *more*. Reason about each project's config shape (Traps: fleet-live
  edits) — the path is config-independent (no new keys).
- **Risk: cooldown collides with a real state-schema expectation.** Mitigation:
  `cooldowns` is an open map already carrying multiple `reason` values; a new
  `transient_stuck` reason is additive.

## Out of scope

- **Why `shipyard-proctor` stalls mid-run** (Claude API stream stall before
  tests). That is the underlying infra/API symptom; the medic's `transient`
  classification of it is correct. File separately if it recurs.
- Changing the medic scan cadence, the retry (`sleep 30`) logic, or any other
  classification arm.
- Config-gating the cooldown behind a key (D-1 default: not gated — this restores
  documented intent, not a new capability).
- A global notify rate-limiter / de-dup layer across all alert types (broader
  redesign; this ticket closes the specific gap).

## Decisions (default-and-record — veto at review)

| # | Decision | Locked default | Why |
|---|---|---|---|
| D-1 | Config-gate the new cooldown? | **No** — fix unconditionally | It restores the `:1006` "don't loop again" intent and matches every sibling path; unset/default is the intended behavior, not a new capability. Veto → gate behind a `[medic] transient_stuck_cooldown_hours` key (0 = today's storm). |
| D-2 | Freeze duration | **24h** (mirrors forbidden/infra `:987`) | Id rolls at UTC midnight anyway, so effective policy is "once per UTC day," matching `restart`. Veto → set a different window. |
| D-3 | `reason` label | **`transient_stuck`** | Distinguishes it in `medic-state.json` / `medic.incident.frozen` events from `forbidden`/`restart`/`self_failure`. |
