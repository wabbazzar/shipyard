# Transient API-stall storm — retry the stall + cool down the alert

- **Status:** draft (ready for `polish-ticket`; awaiting human stamp)
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 6 (P1 2 · P2 1 · P3 3)

## Summary

The 2026-07-24 Signal storm had **two coupled defects**, both fixed here:

1. **The trigger (spawn_model, `agents/lib/spawn.sh`)** — a single transient
   Anthropic SSE stall (`API Error: Response stalled mid-stream`) fails the whole
   `shipyard-proctor` daily run because `spawn_model` has **no retry**. Add a
   bounded retry on the transient-stall signature (never on a real timeout), so
   one flaky stream no longer sinks a run. This is the fleet-wide dispatcher, so
   every role (design/build/release/medic/scribe) benefits.
2. **The amplifier (medic, `agents/medic/runner.sh:1007`)** — once a unit is
   `failed`, the medic scan's `transient`→`stuck` notify path is the **only**
   classification that notifies without recording a cooldown, so it re-alerts the
   identical message every 10-min tick. Record a cooldown (as every sibling class
   already does) so a persistent incident alerts **once per UTC day**.

Defect 1 stops most stalls from failing a run at all; defect 2 stops the alert
spam when something *does* stay broken. Both are needed: the retry reduces
frequency, the cooldown bounds the blast radius.

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

## Problem / Background — defect 1: the transient API stall (diagnosed)

**Captured signature (this repo's own crew, 2026-07-24).** `shipyard-proctor`
ran `agents/release/runner.sh --mode daily` at 04:30:31Z and **exited 1 at
04:34:43 CDT** (systemd: `status=1/FAILURE`, only 3.25s CPU — it was *waiting*
on the network, not computing). Its own log
(`tmp/shipyard-proctor-last-run.log`, read 2026-07-24) is unambiguous:

```
[shipyard-proctor] 2026-07-24T09:30:31Z start mode=daily
API Error: Response stalled mid-stream. The response above may be incomplete.
[shipyard-proctor] claude run wrote no result.json; synthesized failure result
[shipyard-proctor] done pass=false exit=1
```

**Diagnosis.** This is a **transient Anthropic streaming error** surfaced by the
`claude` CLI itself — the SSE stream stalled server/network-side ~3 min in, the
CLI printed `Response stalled mid-stream` to stderr and exited **1**, wrote no
`result.json`, and `release/runner.sh:221-227` synthesized a failure result. It
is **not a shipyard code bug, not a test regression, and not a timeout** — the
run exited at ~3 min, far under `WALL_CLOCK` (default 3600s, `runner.sh:81`), so
the exit code is **1, not 124**. That distinction is the whole handle for the
fix: RC=1 + a stall signature = retry; RC=124 = a real runaway, never retry.

**Where the retry belongs.** Every role's model call funnels through
`spawn_model` in `agents/lib/spawn.sh` (`release/runner.sh:209-212`). Reading it
(2026-07-24): the invocation is `SPAWN_RAW="$(timeout … claude -p … 2>>logfile)"
|| SPAWN_RC=$?` (`spawn.sh:73-77`) with **no retry anywhere** in any of the three
harness paths. So one stall is fatal for whichever role hit it — and the daily
digest that morning shows it is **not** proctor-only (`bopthere-proctor: 0 pass,
2 fail` same day). Fixing it once in the shared dispatcher covers the fleet.

**Why not caught.** `harness-spawn.bats` proves the *composed argv* is
byte-identical per call-site but never exercises a **non-zero harness exit** —
the retry/no-retry contract on a transient failure was never pinned. Record in
`.agents/gates.md` Traps.

## Technical Requirements

### Defect 1 — retry-on-stall in `spawn_model` (`agents/lib/spawn.sh`)

- **Modify:** the claude path `_spawn_claude` (`spawn.sh:65-86`). Wrap the
  `timeout … claude` invocation (`:72-77`) in a bounded retry loop:
  - Retries: `${SPAWN_STALL_RETRIES:-2}` (see D-4 for the default rationale;
    `0` = today's single-shot behavior byte-for-byte).
  - **Retry only when BOTH hold:** `SPAWN_RC != 0` **and** `SPAWN_RC != 124`
    (124 = wrapper timeout, a real runaway — never retry) **and** the attempt's
    output carries a transient-stall signature. Match, case-insensitively, on the
    tail of `$logfile` (stderr lands there via `2>>"$logfile"`) with a fallback
    scan of `$SPAWN_RAW`: `Response stalled mid-stream|overloaded_error|Connection
    error|error 5[0-9][0-9]|429 |529 `. Any other non-zero exit (a real failure
    the model reported) is **not** retried.
  - Backoff between attempts: short, deterministic-ish (e.g. 5s, then 15s). Use a
    fixed schedule, not `RANDOM` — the runners run `set -uo pipefail` and tests
    are hermetic; a jitter source would make the bats case flaky.
  - On a retried attempt, re-truncate nothing the caller owns — `spawn_model`
    only re-runs the harness and re-sets `SPAWN_RAW/RC/TEXT/TOKENS`. The caller's
    `: > "$RESULT_FILE"` (`release/runner.sh:205`) already happened once before
    the call; that's fine (a stalled attempt wrote nothing to it).
  - **Token accounting:** `SPAWN_TOKENS` reflects the *final* (successful or last)
    attempt only, as today. A stalled attempt yields ~0 output tokens; note that
    retries add cost but the daily budget gate (`release/runner.sh:154-176`)
    still bounds the day. Do not sum across attempts (would double-count on the
    rare attempt that emitted a partial envelope).
- **Symmetry (D-6):** apply the same retry wrapper to `_spawn_codex`
  (`spawn.sh:116-121`) and `_spawn_hermes` (`:147-152`) so the contract is
  harness-uniform, OR factor a `_spawn_with_retry <fn>` helper the three paths
  call. Default: factor the helper (one implementation, three call sites).
- **No install.sh change required** for the default: `SPAWN_STALL_RETRIES` carries
  its default *inside* `spawn.sh` (`${SPAWN_STALL_RETRIES:-2}`), exactly like the
  runners' `${<ROLE>_MODEL:-sonnet}` default — units need no re-bake to get it.
  Baking is **optional** (only to tune/disable per project); if this ticket adds
  a bake path in `install.sh:544-559`, it must also add a README env-table row
  (house rule). Default plan: no bake, document the env var in the README only.
- **Scope of roles (D-5):** the retry fires for **every** role, including the
  mutation-capable build/medic. See Risks for the double-mutation analysis and
  why the stall's pre-completion abort + build's own dirty-trunk guard make this
  safe.

### Defect 2 — cooldown on the medic transient→stuck path

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
- **No new unit env knob, no config key** for defect 2 — it restores the
  documented "don't loop again" intent to match the established cooldown
  contract; the unset/default behavior after the fix is "alert once per UTC day,"
  the intended behavior, not a new capability. (See Decision D-1 to veto.)
- **`token-caps.bats` must stay green.** Its test 6 asserts every `claude -p`
  call is wrapped in `timeout`; the defect-1 retry loop **keeps** the
  `timeout … claude` wrapping on every attempt, so this holds — but the builder
  must re-run `token-caps.bats` explicitly after touching `spawn.sh`.

## Implementation Plan

Phases are independent and independently committable. P1 (retry) and P2
(cooldown) touch disjoint files (`spawn.sh` vs `medic/runner.sh`) and neither
leaves the system half-broken. Order: retry first (the trigger), cooldown
second (the amplifier), docs/sweep last.

### Phase 1 — `spawn_model` retry-on-stall + regression test (3 pts)
- Wrap the harness invocation in the bounded retry described in Technical
  Requirements (defect 1). Prefer the factored `_spawn_with_retry` helper so
  claude/codex/hermes share one implementation.
- **Regression test** (new file `tests/harness-spawn-retry.bats`, mirroring
  `harness-spawn.bats`'s `make_stub_script claude` scaffold with a call-counter
  file so the stub fails-then-succeeds):
  - **Retries a stall:** stub prints `API Error: Response stalled mid-stream` to
    stderr + `exit 1` on call 1, then a valid envelope on call 2 → assert
    `SPAWN_RC=0`, `SPAWN_TEXT=ok`, and the stub was invoked exactly twice. Must
    fail red on pre-change code (today: one call, `SPAWN_RC=1`).
  - **Never retries a timeout:** stub sleeps past a tiny `--timeout` (or exits
    124) → assert exactly **one** invocation, `SPAWN_RC=124`.
  - **Never retries a real failure:** stub `exit 1` with a non-stall message →
    exactly one invocation (no wasted retries on genuine failures).
  - **`SPAWN_STALL_RETRIES=0` = today's behavior:** one invocation, byte-identical.
- Gate class: **Shell scripts** (`bash -n agents/lib/spawn.sh` + run the tests)
  and **Test suite**; explicitly re-run `token-caps.bats` (timeout-wrap invariant).

### Phase 2 — Medic cooldown on transient→stuck + regression test (2 pts)
- Add the `state_set` cooldown + `medic.incident.frozen` emit to the
  transient→stuck branch (`runner.sh:1007-1009`).
- Add a bats case (the reproduction above) to a medic scan test file
  (mirror `tests/incident-reroute.bats`'s `prep_*` + `run_medic_scan`
  scaffold): two scans, assert exactly one `transient→stuck` notify **and** a
  `cooldowns[<iid>].reason == "transient_stuck"` entry in `medic-state.json`
  after tick 1. Show it failing red against pre-change code first (house rule).
- Gate class: **Shell scripts** (`bash -n` + run) and **Test suite**
  (`bats tests/`).

### Phase 3 — Docs + Traps + full gate sweep (1 pt)
- Record **both** coverage gaps in `.agents/gates.md` Traps appendix: (a) "medic
  scan: every notify path must record a cooldown or it re-alerts every tick — pin
  with a two-scan test"; (b) "spawn_model: a transient stream stall (RC=1 +
  `Response stalled mid-stream`) must retry, a timeout (RC=124) must not — pin
  with a fail-then-succeed harness stub".
- If a `SPAWN_STALL_RETRIES` bake path is added to `install.sh`, add the README
  env-table row (house rule); default plan documents the env var only.
- Run the full gate battery green (see Testing Strategy). No deck/skill
  frontmatter touched, so no `gen-deck-data.py` regen expected — confirm
  `check-deck-fresh.sh` stays clean.

## Testing Strategy

- **Regression — retry (new, P1):** `tests/harness-spawn-retry.bats` — the four
  cases above (retry-a-stall / no-retry-on-124 / no-retry-on-real-failure /
  `SPAWN_STALL_RETRIES=0`-is-today). Hermetic — `claude` is a PATH stub with a
  call-counter; no network/model.
- **Regression — cooldown (new, P2):** the two-scan medic bats case — one notify
  + a `transient_stuck` cooldown recorded. Hermetic.
- **Invariant:** `bats tests/token-caps.bats` — the timeout-wrap assertion must
  stay green after the `spawn.sh` retry change (re-run explicitly).
- **Full suite:** `bats tests/` (**verified baseline 2026-07-24: 209 pass, 0
  fail** — `bats tests/ | grep -cE '^ok '`; CLAUDE.md's "138" is stale). Must
  stay green; the two new cases make it 211.
- **Leak firewall:** `bash scripts/leak-check.sh`.
- **Deck freshness:** `bash scripts/check-deck-fresh.sh` (expected: unchanged).
- **Syntax:** `bash -n agents/lib/spawn.sh agents/*/runner.sh …` per the gate file.

## Acceptance Criteria / Definition of Done

**Defect 1 — retry (P1):**
- [ ] A `claude` stub that emits `Response stalled mid-stream` + `exit 1` then
      succeeds is retried and `spawn_model` returns `SPAWN_RC=0` / `SPAWN_TEXT=ok`
      (stub invoked exactly twice).
- [ ] A `--timeout`-tripped attempt (`SPAWN_RC=124`) is **not** retried (exactly
      one invocation).
- [ ] A non-stall `exit 1` is **not** retried (exactly one invocation).
- [ ] `SPAWN_STALL_RETRIES=0` reproduces today's single-shot behavior exactly.
- [ ] `token-caps.bats` still green (every attempt is `timeout`-wrapped).
- [ ] The new bats file was shown failing red against pre-change code first.

**Defect 2 — cooldown (P2):**
- [ ] The two-scan reproduction now yields **exactly one** `transient→stuck` notify.
- [ ] After tick 1, `medic-state.json` has
      `cooldowns[<iid>].reason == "transient_stuck"` with `frozen_until` ~24h out.
- [ ] A `medic.incident.frozen` event is emitted on the transient→stuck path
      (parity with forbidden/infra/restart).
- [ ] Next UTC day (new `stable_id`) the alert may fire **once** again if still
      failed — persistent breakage is not silenced forever.
- [ ] No change to any other classification's behavior.
- [ ] The new bats case was shown failing red against pre-change code first.

**Roll-up:**
- [ ] `bats tests/` green at **211** (209 baseline + 2 new); `leak-check.sh`,
      `check-deck-fresh.sh`, and the `bash -n` sweep all green; worktree clean.
- [ ] `.agents/gates.md` Traps appendix records **both** gaps (cooldown-per-notify,
      retry-vs-timeout).

## Polish verification (2026-07-24, this box)

Anchors + toolchain proven during polish so a cold agent can trust them:
- Helpers exist: `state_set()` `runner.sh:241`, `emit()` `:920`, `push_action()`
  `:915`, `quartet_notify()` (used at `:1007`); `STATE_FILE` `:215`.
- Transient→stuck notify is at `runner.sh:1007-1008`; the `# Promote to notify;
  don't loop again.` comment is `:1006`. The sibling cooldown to mirror is
  `:987-989` (`until_ts` + `state_set ".cooldowns[…]"` + `emit medic.incident.frozen`).
- **Gates green now:** `bats tests/` = 209 pass / 0 fail; `leak-check.sh` clean;
  `check-deck-fresh.sh` clean.
- **Cooldown repro proven red on unpatched code:** built the two-scan case on
  the `incident-reroute.bats` scaffold → `NOTIFYCOUNT=2` (two identical
  `transient→stuck` notifies). Removed (not committed) — lands as the P2 test.
- **Stall diagnosis proven from artifacts (not inferred):** the exact CLI error
  `API Error: Response stalled mid-stream` is in `tmp/shipyard-proctor-last-run.log`;
  systemd recorded exit **1** (not 124) after ~4 min << `WALL_CLOCK` 3600s; and
  `spawn.sh:72-77` confirmed to have **no retry** on any harness path. The retry
  handle (RC≠124 + stall signature) is therefore real, not speculative.

## Ledger

_(builder appends: per-phase plan + commit hash + honest notes on anything deferred)_

- [ ] Phase 1 — spawn_model retry-on-stall + `harness-spawn-retry.bats` — commit: ____
- [ ] Phase 2 — medic cooldown + two-scan regression test — commit: ____
- [ ] Phase 3 — Traps notes + docs + full gate sweep — commit: ____

## Run it

`execute-ticket docs/tickets/medic-transient-storm-cooldown.md` — **behind the
human gate**; do not build until stamped.

## Dependencies

None. P1 and P2 are independent (disjoint files) and can land in either order;
P3 depends on both.

## Risks & Mitigations

**Defect 1 — retry:**
- **Risk: retrying a mutation-capable role (build/medic) double-applies a partial
  mutation.** Analysis: the stall is a *mid-stream abort* — the model's turn never
  completes, so no `result.json`/final message is produced (exactly what we
  observed: "wrote no result.json"). A tool call that already committed before the
  stall is the only exposure. Mitigation: build's own **dirty-trunk guard** aborts
  a second run that finds an unexpected tree, and medic never invokes build to fix
  itself (self-failure guard, `runner.sh:370`). Net: the retry re-runs a role that
  produced nothing, which is the safe majority case; the rare partial-commit case
  is caught by existing guards. **If the reviewer wants zero exposure, veto D-5**
  (retry read-mostly roles only).
- **Risk: retry storms cost / hammer the API during a real outage.** Mitigation:
  bounded (`SPAWN_STALL_RETRIES:-2`), fixed backoff, and each attempt is still
  `timeout`-wrapped; the daily token-budget gate still bounds the day. A sustained
  outage exhausts 2 retries and fails the run once — then defect-2's cooldown
  bounds the alerting.
- **Risk: false-positive signature match retries a non-transient failure.**
  Mitigation: the signature list is specific (stall / overloaded / 429 / 5xx /
  connection), RC=124 is explicitly excluded, and a bats case pins "non-stall
  `exit 1` → no retry".

**Defect 2 — cooldown:**
- **Risk: masking a genuinely persistent failure by silencing it.** Mitigation:
  the id rolls at UTC midnight, so a still-broken unit re-alerts once/day — same
  policy `restart` uses. Not a permanent freeze.
- **Risk: fleet-live blast radius** — `agents/medic/runner.sh` and
  `agents/lib/spawn.sh` run for **every** installed project on the next timer
  fire. Mitigation: defect 2 only *adds* a cooldown write on a path that today
  writes none (can only reduce alert volume); defect 1's default is env-guarded
  and its `=0` disable is byte-identical to today. Reason about each project's
  config shape (Traps: fleet-live edits) — neither path adds a required config key.
- **Risk: cooldown collides with a real state-schema expectation.** Mitigation:
  `cooldowns` is an open map already carrying multiple `reason` values; a new
  `transient_stuck` reason is additive.

## Out of scope

- **The upstream Anthropic stream stall itself** — we cannot fix the API; we make
  the crew *resilient* to it (retry) and *quiet* about it (cooldown). If stalls
  persist at high rate, that is an Anthropic-side / network incident to raise
  separately.
- Changing the medic scan cadence or its `sleep 30` retry-recheck logic.
- Config-gating the cooldown behind a key (D-1 default: not gated).
- A global notify rate-limiter across all alert types (broader redesign).
- Per-role retry counts / retrying `codex`/`hermes` differently than `claude`
  (D-6 default applies one uniform helper; finer tuning is a follow-up).

## Decisions (default-and-record — veto at review)

| # | Decision | Locked default | Why |
|---|---|---|---|
| D-1 | Config-gate the new cooldown? | **No** — fix unconditionally | It restores the `:1006` "don't loop again" intent and matches every sibling path; unset/default is the intended behavior, not a new capability. Veto → gate behind a `[medic] transient_stuck_cooldown_hours` key (0 = today's storm). |
| D-2 | Freeze duration | **24h** (mirrors forbidden/infra `:987`) | Id rolls at UTC midnight anyway, so effective policy is "once per UTC day," matching `restart`. Veto → set a different window. |
| D-3 | `reason` label | **`transient_stuck`** | Distinguishes it in `medic-state.json` / `medic.incident.frozen` events from `forbidden`/`restart`/`self_failure`. |
| D-4 | Default retry count | **`SPAWN_STALL_RETRIES:-2`** (active by default; `=0` = exact old behavior) | House rule wants "unset == today," but a 0 default leaves the storm unfixed. Compromise: the *disable* path (`=0`) is proven byte-identical by a bats case, while the useful default (2) actually fixes it — same pattern as `${ROLE_MODEL:-sonnet}`. **Reviewer call: accept the fleet-wide behavior change, or set default 0 + opt-in per project.** |
| D-5 | Which roles retry | **All roles** (incl. build/medic) | The stall aborts pre-completion so the retried role usually produced nothing; build's dirty-trunk guard + medic's self-failure guard cover the rare partial-commit case. Veto → read-mostly roles only (release/design/scribe), leaving build/medic single-shot. |
| D-6 | codex/hermes symmetry | **One `_spawn_with_retry` helper, all three harnesses** | Uniform contract, one implementation to test. Signature list stays claude-centric but the RC≠124 + retry structure is harness-agnostic. Veto → claude-only retry for now. |
| D-7 | Bake `SPAWN_STALL_RETRIES` into units via `install.sh`? | **No** — internal default only, document env var in README | Avoids a unit re-bake and a required env-table row; the in-`spawn.sh` default already reaches every unit. Veto (if a project must tune it declaratively) → add the bake path *and* the README row (house rule). |
