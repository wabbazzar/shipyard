# Shipyard dogfood: truthful tickets, a clean doctor, and sane Signal alerts

- **Created:** 2026-07-28
- **Owner:** wabbazzar
- **Status:** Phase 5 in progress; Phase 6 open; phases 1–4 implemented
- **Priority:** high
- **Type:** chore
- **Estimated Points:** 18 (6 phases, cap 5/phase)
- **Refs:** `docs/tickets/ticket-lifecycle-folders.md`,
  `docs/tickets/delegation-plan-pipeline.md`, `.agents/config.toml`,
  `.agents/gates.md`, `agents/lib/load-config.sh`,
  `agents/lib/post-run.sh`, `agents/medic/runner.sh`

## Objective

Make Shipyard obey the hygiene it now ships and make Signal an exception
channel instead of a second operations dashboard.

When this ticket is complete:

1. Shipyard's own tickets live in truthful `pending/`, `complete/`, and
   `freezer/` folders, and its Codex skill bridge passes doctor.
2. Routine scheduled-agent news stays in the event stream and Ice/Daily
   Dispatch. Signal carries direct replies, decisions, release-critic feedback,
   and actionable or urgent failures.
3. One underlying failure produces at most one Signal alert per project and
   episode, including the medic no-result path that caused the 2026-07-28
   cascade.
4. The delegation report can isolate genuinely post-change sessions, and the
   delegation outcome ticket states what is and is not measurable yet.

## Evidence and problem statement

This ticket comes from the harness's live state, not a hypothetical cleanup:

- `install.sh --doctor --project .` currently reports
  `DOCTOR skill bridge: AGENTS.md missing`.
- `.agents/config.toml` still uses flat `docs/tickets`, even though Phase 8 of
  `ticket-lifecycle-folders.md` requires Shipyard to dogfood
  `pending/complete/freezer` with `lifecycle_dirs = true`.
- Several ticket headers describe work as Draft or ready-to-build even though
  their implementation commits are reachable from `main`; folder state is not
  yet available to make that contradiction obvious.
- `scripts/delegation-report.py` has only rolling `--days` and `--all` windows.
  It cannot express the exact merge/cutover timestamp needed for a measurable
  before/after result.
- The shared Ice event stream recorded **123** `notify.send` events on
  2026-07-28. **70** were repeated `Suk (<repo>) FAILED` messages:
  bopthere 17, shipyard 15, aurora 14, starbird 13, shredly 11.
- The repeated page originates at `agents/medic/runner.sh:891-902`: when the
  classifier writes no result, medic notifies and exits without recording a
  cooldown. With a usage-limit failure, each ten-minute timer tick pages again.
- Build and release currently notify on every pass and budget skip
  (`agents/build/runner.sh:175-176,260-266`,
  `agents/release/runner.sh:172-173,327-339`). Those runs and their results are
  already represented in the event stream and Ice Dispatch.
- `agents/lib/post-run.sh:56-64` synchronously invokes medic after a role
  failure, so the originating role and medic can page for the same episode.
- Direct BopBop Signal replies are independent of Shipyard's system
  notification transport. Filtering crew alerts must not change that path.

## User-visible notification contract

The categories are semantic, not merely shorter prose:

| Class | Examples | Signal at fleet `actionable` level |
|---|---|---|
| routine | pass, budget skip, rate-limit/no-result retry, incomplete run already visible in Dispatch | no |
| actionable | genuine gate failure, unresolved incident, approval/decision needed, critic fallback | yes, once per episode |
| urgent | unsafe stop, failed recovery/restart, live outage | yes, once per episode |

The event stream remains complete regardless of Signal suppression. Ice/Daily
Dispatch remains the place to read routine operations and news. The setting
must filter only Shipyard-originated system notifications; it must not filter
BopBop conversation replies.

## Decisions

### Locked

1. Add `[notify].signal_level = "actionable"` to the active fleet. Unset keeps
   today's delivery behavior for backward compatibility.
2. Classified calls use
   `quartet_notify --class <routine|actionable|urgent> [--episode <key>]`
   `[--window <seconds>] <title> <body>`. Existing two-argument
   `quartet_notify <title> <body>` remains valid and preserves today's behavior.
3. Deduplication is keyed by project + cause/fingerprint + a bounded window.
   Message text alone is not a stable key.
4. Release-critic fallback and user-decision messages remain actionable.
5. Routine suppression never removes job, incident, proposal, or approval
   records from JSONL/dashboard inputs.
6. Caladan is a dummy fixture repository and is excluded from live fleet
   migration.
7. Ticket classification follows git reachability plus each ticket's actual
   acceptance/ledger. A stale prose header does not overrule shipped commits,
   and an incomplete acceptance checklist does not become complete merely
   because related code exists.
8. The delegation outcome is reported honestly. Add the exact cutoff and
   record an insufficient sample if fewer than five post-change executions
   exist; never blend pre-change sessions or invent runs.
9. Levels are ordered `routine < actionable < urgent`; accepted policies are
   `all`, `actionable`, `urgent`, and `off`. Unset means `all`. An invalid policy
   fails open to `all` and records `reason=invalid_policy`, so a typo cannot
   swallow an urgent page.
10. Default dedup window is 86,400 seconds. Suppression never consumes a key;
   a delivered notification consumes it only after transport exit 0. Urgent
   messages are also deduped when they share an explicit episode.
11. The stale backlog duplicate named before this ticket was drafted is already
   absent: a basename scan across every active repo found no duplicate ticket.
   Phase 5 records that evidence; it does not delete an unrelated file.
12. `quartet_notify` reads the caller's already-loaded `CFG_JSON`; it does not
    reread TOML on each send. Dedup state lives under the caller's project
    `tmp/`, protected by `flock` around read/modify/write and atomic rename.
13. Every classified decision emits `notification.decision` with class,
    episode, and `delivered|suppressed|deduped`; legacy two-argument calls do not
    gain new behavior. Existing job/incident/proposal events remain independent.
14. The originating role derives one stable episode from project, role, mode,
    cause, and result fingerprint, then `post-run.sh` passes that exact value to
    medic. Medic never regenerates a timestamp-based key for the handoff.
15. The release-critic owner fallback stays outside scheduled-noise filtering:
    it is direct author feedback and must remain deliverable when a project
    selects `signal_level = "actionable"`.

### User-decision class

None. The owner explicitly delegated the Signal policy choice and requested the
full `write-ticket → polish-ticket → execute-ticket` pipeline. Defaults above
are reversible and keep routine data in the existing dashboard.

## Boundaries

In scope:

- Shared notification API, call-site classification, episode deduplication,
  tests, documentation, and active-fleet configuration.
- Root-cause fix for the medic classifier no-result cascade.
- Shipyard's lifecycle configuration, ticket migration, stale status
  reconciliation, root `AGENTS.md` bridge, and doctor verification.
- An exact `--since` cutoff for the delegation report and a truthful update to
  the existing delegation ticket.

Out of scope:

- Redesigning Ice/Daily Dispatch or the BopBop Signal conversation path.
- Suppressing unrelated host security alerts such as fail2ban.
- Generating synthetic agent sessions merely to satisfy an outcome sample.
- Migrating Caladan.
- New product features unrelated to harness health.

## Definition of Done

- [ ] A pre-change failing Bats fixture proves `signal_level=actionable`
      suppresses routine sends while retaining actionable and urgent sends;
      unset config preserves existing behavior.
- [ ] A pre-change failing Bats fixture proves repeated medic no-result scans
      emit one alert for the same project/cause/window, not one per timer tick.
- [ ] Build, release, scribe, medic, and overseer notification call sites have
      explicit classifications; critic fallback remains a directly tested,
      always-actionable exception.
- [ ] A role failure followed by medic does not double-page the same episode.
- [ ] Direct BopBop replies remain functional and release-critic fallback still
      delivers.
- [ ] Suppressed routine activity still appears in the event stream and a real
      Ice Dispatch generation succeeds.
- [ ] `notification.decision` distinguishes delivered, policy-suppressed, and
      episode-deduped sends without replacing the underlying job/incident event.
- [ ] The active non-dummy fleet uses the actionable Signal level.
- [ ] A 24-hour measurement command reports zero routine Shipyard crew sends
      and no more than one actionable send per project/cause/window. If 24
      elapsed hours are unavailable during execution, record a timestamped
      baseline plus an exact follow-up command; do not claim the elapsed result.
- [ ] Shipyard's `[write_ticket]` enables lifecycle folders and every existing
      ticket is classified into exactly one of `pending/`, `complete/`, or
      `freezer/`, with its header and ledger reconciled to git reality.
- [ ] `install.sh --doctor --project .` exits 0 and validates the Codex/Hermes
      skill bridge.
- [ ] `delegation-report.py --since <ISO-8601>` excludes older turns and has
      hermetic fixture coverage for boundary timestamps and malformed input.
- [ ] `delegation-plan-pipeline.md` records the exact cutover and current
      post-change sample without claiming an outcome before at least five real
      executions exist.
- [ ] Every phase's named gates and the complete `.agents/gates.md` battery are
      green; commits are on `main` and pushed.

## Phases

Each Shipyard phase is one verified commit on `main`. The fleet phase makes one
scoped config commit per repository and records every SHA. Scope `git add` to
named files, never `git add -A`. Subagents do not commit or push; the
orchestrator reruns gates, commits, and pushes. Every delegated brief includes:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

### Phase 1 — Notification policy primitive (3 pts)

**Delegation:** subagent — allowed files:
`agents/lib/load-config.sh`, `tests/helpers.bash`,
`tests/harness.bats`, `tests/notification-policy.bats`; implement the locked
classified API and failing-first fixtures. Do not edit runners, commit, or
push. Return ≤40 lines: files changed, commands + exit codes, exact assertions,
blockers.

- Extend the shared notification helper with `routine`, `actionable`, and
  `urgent` classes plus an explicit episode key/window.
- Read the project `[notify]` policy at runtime so existing installed units do
  not require a new secret-bearing environment channel.
- Keep the current two-argument call valid and byte-compatible when the setting
  is unset.
- Store dedup state in the project-local ignored `tmp/`, with `flock` plus
  temp-file/rename around the whole update; never place machine data in tracked
  files.
- Tests cover unset compatibility, each level, dedup expiry, different keys,
  urgent dedup, a failed transport that does not consume the key,
  concurrent-safe state handling, invalid-policy fail-open, and
  `notification.decision` events.

**Phase gate:** focused notification Bats file, syntax sweep, leak-check, then
the full gate battery from `.agents/gates.md`.

```bash
bats tests/harness.bats tests/notification-policy.bats
bash -n agents/lib/load-config.sh
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bats tests/
```

### Phase 2 — Classify call sites and stop the medic cascade (5 pts)

**Delegation:** subagent — allowed files: `agents/{build,release,scribe,medic,
overseer}/runner.sh`, `agents/lib/post-run.sh`,
`tests/medic-no-result-cooldown.bats` and directly affected runner tests.
Classify calls, implement the no-result cooldown and stable post-run episode;
do not edit the critic, config, commit, or push. Return ≤40 lines with a
path:line classification table, commands + exit codes, evidence, blockers.

- Routine: successful scheduled runs, budget/rate-limit skips, and incomplete
  runs already represented in Dispatch.
- Actionable: genuine failed gates, unresolved incidents, approval/decision
  needs, overseer findings, and critic fallback.
- Urgent: unsafe stop, outage, and failed recovery/restart.
- Fix `agents/medic/runner.sh`'s no-result path with a stable failure
  fingerprint and cooldown written before exit. Two identical scans send once;
  a changed classifier exit/cause is a different episode.
- Give an originating role failure and its post-run medic escalation the same
  episode key so they cannot double-page. Derive it once from the originating
  result fingerprint and pass it through `post-run.sh`.
- Preserve Scribe's no-escalate behavior and critic direct delivery order.

**Phase gate:** focused runner/medic/critic Bats files, two-scan cascade fixture,
syntax sweep, leak-check, then the full gate battery.

```bash
bats tests/notification-policy.bats tests/medic-no-result-cooldown.bats \
  tests/harness.bats \
  tests/incident-reroute.bats tests/medic-transient-cooldown.bats \
  tests/release-incomplete-notify.bats tests/overseer.bats \
  tests/shoulder-mode-harness.bats
bash -n agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bats tests/
```

### Phase 3 — Shipyard policy, documentation, and controlled probes (2 pts)

**Delegation:** subagent — allowed files: `.agents/config.toml`, `README.md`,
and notification tests only. Add Shipyard's actionable policy and document the
API/settings. Do not touch downstream repos, commit, push, or contact Signal.
Return ≤40 lines with scoped diff, focused/full gate exit codes, and evidence.

- Configure Shipyard with `[notify].signal_level = "actionable"` and the
  locked default dedup window.
- Document the policy values, classified API, event record, and unset
  compatibility.
- Prove delivery/suppression/dedup with the hermetic transport stub. A real
  Signal self-message is optional and requires a separate explicit owner
  authorization; it is not an automated gate.
- Confirm `--check-config` exposes the effective policy where role runners
  already have that read-only surface.

**Phase gate:**

```bash
bats tests/harness.bats tests/notification-policy.bats \
  tests/medic-no-result-cooldown.bats
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bats tests/
```

### Phase 4 — Six downstream policies and Ice/BopBop verification (3 pts)

**Delegation:** one subagent brief per downstream repository — only
`.agents/config.toml` may change. Return ≤40 lines each: pre/post status,
scoped diff, project gate rc, doctor rc, proposed commit; do not commit/push.
The orchestrator serializes repos, re-verifies, makes one scoped commit per
repo, and records/pushes every SHA.

- Configure Aurora, Bopthere, Shredly, Starbird, 2pizzaclub, and Ice; Caladan
  is excluded. With Shipyard from Phase 3, that is seven configured repos.
- Begin with `git status --short --branch`. Aurora and Ice were observed on
  local `publish/ticket-lifecycle` branches ahead of their remotes while this
  ticket was polished. Reconcile and push those already-authorized migration
  commits onto trunk first; never absorb unknown dirty files.
- Reinstall only if the implementation actually requires generated-unit drift.
- Prove BopBop conversation independence with its hermetic thread tests; do not
  use a real inbound/outbound Signal message as a gate.
- Generate Ice Dispatch with its service virtualenv and prove routine crew
  activity remains represented.

Use each repo's `.agents/gates.md`. Primary project gates observed at polish:
Aurora `.venv/bin/python -m pytest`; Bopthere `npx vitest run`; Shredly
`npm test`; Starbird `npx vitest run && npx svelte-check --threshold error &&
npm run build`; 2pizzaclub `node tools/rag-eval.mjs`; Ice has no monolithic
suite, so use its named component gates.

```bash
for repo in aurora bopthere shredly starbird 2pizzaclub wabbazzar-ice; do
  git -C "$HOME/code/$repo" status --short --branch
  bash "$HOME/code/shipyard/install.sh" --doctor --project "$HOME/code/$repo"
done
cd "$HOME/code/bopbop/server" &&
  .venv/bin/pytest -q tests/test_api_thread_record.py tests/test_thread_awareness.py
cd "$HOME/code/wabbazzar-ice" &&
  .venv/bin/python scripts/newspaper.py --no-prose --stdout | jq .
```

### Phase 5 — Shipyard lifecycle and Codex doctor dogfood (3 pts)

**Delegation:** subagent — allowed files: `.agents/config.toml`, `AGENTS.md`,
and `docs/tickets/**`. First return all 13 current
filename → complete/pending/freezer → header/ledger/git evidence in ≤40 lines;
the orchestrator validates that map, then authorizes the deterministic moves.
Do not edit installer/core scripts, commit, or push.

- Change `[write_ticket]` to:
  `ticket_dir = "docs/tickets/pending"`,
  `archive_dir = "docs/tickets/complete"`,
  `backlog_dir = "docs/tickets/freezer"`,
  `scan_dirs` covering all three, and `lifecycle_dirs = true`.
- Record that the authorized stale backlog duplicate is absent across the
  active fleet; remove one only if the basename audit identifies exact
  duplicate paths and git history proves which copy is stale.
- Reconcile ticket status/ledger text to shipped commits before moving files.
- The lifecycle engine scans only configured lifecycle directories; it does not
  discover legacy files in the flat root. Audit and `git mv` the current flat
  files first, then enable the config, then run `--check`. Do not enable the
  config first and mistake an empty scan for a successful migration.
- Create/reconcile the root `AGENTS.md` via the installed bridge mechanism;
  do not hand-maintain a divergent skill list.
- Run doctor on Shipyard and verify skill resolution from a real Codex session
  context.

**Phase gate:** ticket lifecycle checker, install/doctor/skill tests,
`install.sh --doctor --project .`, syntax/leak/deck checks, then full Bats.

```bash
find docs/tickets -type f -name '*.md' -printf '%f\n' | sort | uniq -d
bats tests/ticket-lifecycle-script.bats tests/ticket-lifecycle-install.bats \
  tests/install-skills.bats tests/relink.bats tests/doctor.bats
bash install.sh --relink --project .
bash scripts/ticket-lifecycle.sh --project . --check
bash install.sh --doctor --project .
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bats tests/
```

### Phase 6 — Measurable delegation cutoff and truthful closeout (2 pts)

**Delegation:** subagent — allowed files:
`scripts/delegation-report.py`, `tests/delegation-report.bats`, and the two
pipeline tickets. Add the exact boundary and recursive lifecycle ledger scan;
do not manufacture sessions, commit, or push. Return ≤40 lines with commands +
exit codes, exact cutoff/sample/metrics/ledger counts, and blockers.

- `--since` is timezone-aware and inclusive. It conflicts with either
  explicitly supplied `--days` or `--all` and exits 2; invalid input also exits
  2 with a useful error.
- Naive ISO timestamps are invalid. Malformed transcript timestamps are skipped
  and counted in the report instead of silently disappearing. A timestamp
  exactly equal to the boundary is included.
- Ticket discovery scans lifecycle directories after Phase 5.
- Update `delegation-plan-pipeline.md` with the exact cutoff, current sample,
  and whether its five-session outcome gate is measurable.
- Record the Signal baseline and exact 24-hour follow-up query in this Ledger.
- Graduate this ticket after every immediately executable acceptance item is
  green and the Ledger names the 24-hour follow-up owner, UTC due time, and
  exact query. That named follow-up satisfies the time-deferred item; it is not
  a claim that 24 hours already elapsed.

**Phase gate:** delegation-report fixtures and real read-only run, lifecycle
gate, syntax/leak/deck checks, full Bats, doctor, clean status, push.

```bash
bats tests/delegation-report.bats
python3 scripts/delegation-report.py --since <recorded-UTC-cutover> --json
bash scripts/ticket-lifecycle.sh --project . --check
bash install.sh --doctor --project .
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py scripts/delegation-report.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
node scripts/check-deck-render.mjs  # rc 3 is the documented optional skip
bats tests/
```

## Polish findings

- Existing job, incident, proposal, and approval events—not Signal—are the
  routine source of truth. Filtering must not gate those event writes.
- Severity filtering alone cannot stop the observed storm because the medic
  classifier failure is actionable and currently has no cooldown. Phase 2
  therefore requires both classification and episode deduplication.
- `post-run.sh` is the cross-role handoff. Pass a stable episode id into its
  synchronous medic invocation instead of inferring identity from two titles.
- The two-argument helper case is load-bearing because project-owned callers
  may not adopt classified options in the same commit.
- A 24-hour result cannot be manufactured in one execution. Acceptance is a
  timestamped baseline, installed query, and immediate two-scan probes; the
  elapsed result remains a named follow-up.
- The lifecycle engine does not migrate flat roots, and the live fleet is not
  uniformly on a clean trunk. Both operations need explicit ordering.
- No open decision remains. The owner delegated the policy choice and requested
  automatic progression to execute-ticket.

## Ledger

- 2026-07-28 — Draft created from the owner-requested dogfood pipeline.
- 2026-07-28 — `builder: subagent (1 audit agent)` for investigation:
  123 sends observed; 70 repeated medic classification-failure pages; exact
  control points and notification classification returned in ≤40 lines.
- 2026-07-28 — Polished with exact phase gates, a stable cross-role episode
  handoff, flat-to-lifecycle ordering, and a non-fabricated 24-hour contract.
- 2026-07-28 — Phase 1 built; `builder: subagent (1 agent)`. Failing-first
  fixture: 1/9 passed before implementation, cases 2–9 failed. Final focused:
  32/32; full: 370/370. Orchestrator review added the dedup-lock fail-open case:
  an unavailable lock delivers with `reason=dedup_unavailable` rather than
  swallowing an urgent alert.
- 2026-07-28 — Phase 2 built; `builder: subagent (1 agent)`. Both new
  failing-first cases initially double-paged. Final focused: 76/76; full:
  374/374. One result fingerprint now flows from the originating role through
  `post-run.sh` into medic; identical classifier failures and origin→medic
  escalation each produce `delivered,deduped` and one transport send. Failed
  restart is urgent; passes, budget skips, and incomplete runs are routine.
- 2026-07-28 — Phase 3 built; `builder: subagent (1 agent)`. Shipyard's ignored
  live `.agents/config.toml` now sets `signal_level = "actionable"`; it is not
  force-added because it contains machine-local install state. Tracked README
  and hermetic-test changes prove the policy without Signal contact. Focused:
  35/35; full: 375/375. No dead `dedupe_window_sec` key was added: the consumed
  default is 86,400 seconds and `--window` is the supported override.
- 2026-07-28 — Phase 4 built; `builder: subagent (1 reusable audit agent; six
  bounded repository briefs)`. The actionable Signal policy is live in all six
  downstream repos: Aurora `3446928` on `main` (also merged into its live
  product branch at `5f3353f`; clean-origin suite 462 passed/6 skipped),
  Bopthere `c9377d3` (320 frontend and 265 backend passed/1 skipped), Shredly
  `ba9ef8bd` (4,744 passed/4 skipped), Starbird `0a23a41` (23 passed,
  svelte-check 0 errors, static build green), 2pizzaclub `dcff523` (RAG 5/5),
  and Ice `4093b33`. Each doctor reports checks a–j clean. Ice's five
  hub-only decisions were recovered to canonical project ledgers; the tracked
  Aurora recovery shipped in `3446928` and Bopthere's two recoveries in
  `8e25500` after a fresh 320/320 + 265/1 gate. Ice Dispatch edition 209
  generated with 7 desks and 73 items, proving routine news remains available
  outside Signal. BopBop's independent conversation/thread fixtures passed
  17/17. Caladan remained excluded as the owner directed.
- 2026-07-28 — Phase 5 planned; `builder: subagent (1 audit/build agent)`.
  Read-only audit found 13 unique flat tickets and no stale backlog duplicate:
  seven have complete commit-backed Ledgers; six are unfinished or lack enough
  evidence and will remain pending. Nothing is authorized for `freezer/`.
- 2026-07-28 — Phase 5 built. All 13 tickets are uniquely filed (7 complete,
  6 pending, 0 freezer); the ignored live config enables lifecycle directories,
  and installer-generated `AGENTS.md` advertises all seven skills. Focused
  lifecycle/install/relink/doctor gates: 56/56; lifecycle check, doctor checks
  a–j, duplicate scan, syntax, leak, deck freshness, and deck render: green.
  A separate ephemeral Codex session discovered
  `.agents/skills/shipyard/SKILL.md`, ran the skill's deterministic status
  command, and reported doctor clean with exit 0. A deliberately `read-only`
  Codex sandbox could not query the systemd user bus and therefore reported
  five false disabled-timer findings; the normal full-permission installed
  session is the verified operating surface.
