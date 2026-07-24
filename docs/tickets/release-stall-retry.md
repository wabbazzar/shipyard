# Release runner: retry a transient mid-stream model stall before failing the job

- **Created:** 2026-07-24
- **Owner:** wabbazzar
- **Status:** Polished — ready for `execute-ticket`; queued for a human stamp (not built)
- **Type:** bug
- **Estimated Points:** 5 (P1 3 · P2 2)
- **Refs:** `agents/release/runner.sh` (batch release/proctor job),
  `agents/lib/release-verdict.sh` (`release_incomplete`), `agents/lib/spawn.sh`
  (`spawn_model`), `agents/release/critic-watch.sh:359-389` (shoulder-mode
  model retry — the precedent), `agents/lib/post-run.sh` (job.end + medic
  escalation trailer). Origin: mentat proposal `mentat:shipyard:3b5a75e8`.

> Build with `execute-ticket`. Orchestrate: delegate wide reads to subagents,
> re-verify every gate personally. **Anti-cheating brief (verbatim):** Converge
> honestly or report the precise blocker with the actual evidence — NEVER fake
> green, weaken a check, or hand-wave "should work". Run the real command, read
> the real file, and report exact output (exit codes, JSONL lines,
> result.json contents), not adjectives.

## Goal

A transient API stall mid-stream in the **batch release (proctor) job** — the
model connection stalls before any test/lint step runs or before `result.json`
is written — currently fails the whole job (`JOB_STATUS=fail`), and medic's
blind retry is the only mitigation. Retry the model call **in-process** with
backoff when (and only when) the run looks like a transient stall, so a
one-off network hiccup self-heals instead of triggering a medic retry/escalation
storm.

## Problem / evidence (baseline — measured 2026-07-24)

Two medic incidents sharing one `incident_id` fired 10 minutes apart, same
failure class:
- `incident_id 9da68ea4…80590` @ `2026-07-24T09:41:18Z` — "API response stalled
  mid-stream before any test/lint step ran — one-off, retrying".
- again @ `2026-07-24T09:51:27Z` — "API stream stalled mid-run before writing
  result.json — no test/gate failure seen, retrying once".
- both `restart_action retry:still_failing`, correlates with `job_fail:2`.

No actual gate failed — the model stream stalled. The batch runner spawns the
model exactly **once** (`agents/release/runner.sh:211` `spawn_model`); if no
`result.json` is written it synthesizes a failure result (`:223`) and
`JOB_STATUS=fail` (`:238`). `release-verdict.sh` (added 2026-07-24) already
detects this as INCOMPLETE (`:247`), stamps `result.json .incomplete=true`, and
emits an honest "DID NOT FINISH" notify (`:285`) so the dashboard no longer
mints a false dispatch item — **but** `JOB_STATUS` stays `fail`, so medic still
escalates. That closes the *notification* symptom, not the *retry-storm* one.

## Scope correction (read before building)

The proposal named `critic-queue.sh` / `critic-watch.sh`. But
`critic-watch.sh:359-389` **already** retries the model up to 3× on an
empty/failed run — the shoulder-mode path is covered. The real gap is the
**batch runner** (`agents/release/runner.sh`), which has no in-process retry.
Build the retry there. Do **not** duplicate retry logic into the critic scripts.

## Decisions

**Locked:**
- The stall predicate is the existing `release_incomplete "$EXIT"
  "$RESULT_FILE"` (a transient stall = no usable `result.json` + a
  timeout/kill/`run-in-progress` signature). A genuine gate failure —
  `result.json` present with `pass:false` and real `errors[]` — is NOT a stall
  and MUST NOT be retried.
- Medic's retry/escalation policy for genuine failures is unchanged.
- Wall-clock timeout and token-cap values are unchanged (out of scope).
- Backoff between retries is a short fixed sleep (a few seconds); this is not a
  tight loop against a rate limit.

**USER-DECISION — do NOT invent a default; surface to the owner (spend +
live-automation behavior):** how many in-process model retries on a transient
stall, fleet-wide. Each retry is **one extra model spend** (tokens + wall-clock)
on a stalled run.
- Option A (safe ship, opt-in): new config key `[release] stall_retries`,
  **unset = 0 = today's behavior exactly**. Projects opt in per-repo. Zero fleet
  behavior change until the owner sets it.
- Option B (fleet self-heal): default `stall_retries = 1`. One transient stall
  is absorbed everywhere at the cost of up to one extra model run per stalled
  job.

  **In the meantime the builder ships Option A** (`stall_retries` default 0 —
  provably today's behavior) so the change is safe unstamped; flipping the fleet
  default to 1 is a one-line follow-up the owner approves separately.

## Implementation plan

### P1 — config-gated in-process stall retry (3 pts)
- Add `[release] stall_retries` to config parsing in `runner.sh` (jq with
  `// 0` default; validate integer; clamp to a small max e.g. 3).
- Wrap the `spawn_model` call (`:211`) in a loop: after each spawn, if
  `result.json` is usable → break; else if `release_incomplete` (transient
  stall) AND attempts remain → `log` the retry, short backoff, respawn; else
  proceed to the existing failure path unchanged.
- Emit a `release.stall.retry` (or reuse an existing event name — check
  `log_event.sh` callers) JSONL line per retry so the behavior is observable in
  the event stream.
- Files: `agents/release/runner.sh` only.
- **Verification surface (test-first bats, each must fail on pre-change code):**
  - `stall_retries` unset → `spawn_model` (stubbed) called **exactly once**
    (byte-identical to today's behavior) — pins Option A safety.
  - `stall_retries=1`, stub first spawn = stall (no result.json), second spawn
    writes a `pass:true` result → job ends `ok`/`partial`, exactly **one**
    retry event, `agent_finish` receives a non-fail status (assert no medic
    escalation path taken).
  - `stall_retries=2`, a genuine `pass:false` result on the first spawn → **no
    retry** (real failures are not stalls); one spawn, `JOB_STATUS=fail`.
  - Stub `spawn_model` via the existing PATH-shim harness (`make_stub`) so no
    test reaches a model.
- **Gates:** `bash -n agents/release/runner.sh`; `bats tests/` (full, ~23s);
  `bash scripts/leak-check.sh`. No skill frontmatter touched → no deck regen.

### P2 — README env/config doc + Traps note (2 pts)
- Document `[release] stall_retries` in the README config/knobs table (default
  0, what a retry costs). Add a one-line Traps note in `.agents/gates.md` for
  the release project: "a stalled model stream is retried in-process up to
  `stall_retries` times before the job fails — a stall is NOT a gate failure."
- **Gate:** the change is docs only; re-run `bats tests/` to confirm nothing
  reads the table programmatically, and `leak-check`.

## Testing strategy

`bats tests/` with the PATH-shim harness (`make_stub spawn_model` / stubbing the
harness binary) — deterministic, no network, no model. Each new case is shown
failing against pre-change `runner.sh` first, then green.

## Definition of Done (checklist)

- [ ] `[release] stall_retries` parsed in `runner.sh`, default 0, integer-validated.
- [ ] Unset default → exactly one model spawn (bats proves byte-parity with today).
- [ ] A transient stall with `stall_retries>=1` retries in-process and the job
      does NOT reach medic escalation (bats).
- [ ] A genuine `pass:false` result is NEVER retried (bats).
- [ ] One observable event per retry in the event stream.
- [ ] `bats tests/` full suite green; `leak-check` clean; `bash -n` clean.
- [ ] README documents the knob and its spend; `.agents/gates.md` Traps note added.
- [ ] Owner has chosen the fleet default (A stays 0, or B → 1) — recorded here.

## Out of scope

- `critic-watch.sh` / `critic-queue.sh` (shoulder mode already retries 3×).
- Medic's retry/escalation policy for genuine failures.
- Wall-clock timeout / token-cap values.
- The notification title + dashboard dispatch-minting (already fixed by
  `release-verdict.sh`, 2026-07-24).

## Ledger

_(empty — builder appends plan + commit hash per phase)_

---
Run it with `execute-ticket` once stamped.
