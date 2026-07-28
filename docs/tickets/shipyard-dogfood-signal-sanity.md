# Shipyard dogfood: truthful tickets, a clean doctor, and sane Signal alerts

- **Created:** 2026-07-28
- **Owner:** wabbazzar
- **Status:** Draft
- **Priority:** high
- **Type:** chore
- **Estimated Points:** 15 (5 phases, cap 5/phase)
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
2. Notification calls declare a class explicitly. Existing two-argument
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
- [ ] Build, release, scribe, medic, overseer, and critic notification call
      sites have explicit, reviewed classifications.
- [ ] A role failure followed by medic does not double-page the same episode.
- [ ] Direct BopBop replies remain functional and release-critic fallback still
      delivers.
- [ ] Suppressed routine activity still appears in the event stream and a real
      Ice Dispatch generation succeeds.
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

Each phase is one verified commit on `main`. Scope `git add` to named files,
never `git add -A`. Every delegated brief includes:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

### Phase 1 — Notification policy primitive (3 pts)

**Delegation:** subagent — implement the backward-compatible classified
notification API and hermetic Bats fixtures; return ≤40 lines: files changed,
commands + exit codes, exact assertions, blockers.

- Extend the shared notification helper with `routine`, `actionable`, and
  `urgent` classes plus an explicit episode key/window.
- Read the project `[notify]` policy at runtime so existing installed units do
  not require a new secret-bearing environment channel.
- Keep the current two-argument call valid and byte-compatible when the setting
  is unset.
- Store dedup state in a project-local ignored runtime path with atomic updates;
  never place machine data in tracked files.
- Tests cover unset compatibility, each level, dedup expiry, different keys,
  concurrent-safe state handling, and complete event logging.

**Phase gate:** focused notification Bats file, syntax sweep, leak-check, then
the full gate battery from `.agents/gates.md`.

### Phase 2 — Classify call sites and stop the medic cascade (5 pts)

**Delegation:** subagent — classify every Shipyard notification call site,
implement the medic no-result cooldown and cross-role episode key, and return
≤40 lines with a path:line classification table plus focused/full test results.

- Routine: successful scheduled runs, budget/rate-limit skips, and incomplete
  runs already represented in Dispatch.
- Actionable: genuine failed gates, unresolved incidents, approval/decision
  needs, overseer findings, and critic fallback.
- Urgent: unsafe stop, outage, and failed recovery/restart.
- Fix `agents/medic/runner.sh`'s no-result path with a stable failure
  fingerprint and cooldown written before exit.
- Give an originating role failure and its post-run medic escalation the same
  episode key so they cannot double-page.
- Preserve Scribe's no-escalate behavior and critic direct delivery order.

**Phase gate:** focused runner/medic/critic Bats files, two-scan cascade fixture,
syntax sweep, leak-check, then the full gate battery.

### Phase 3 — Fleet policy and live notification verification (2 pts)

**Delegation:** subagent — audit the six active fleet configs and installed
units, apply only the `actionable` policy, and return ≤40 lines: repo/commit,
doctor rc, effective policy, notification probe evidence, blockers.

- Configure Aurora, Bopthere, Shredly, Starbird, 2pizzaclub, Ice, and Shipyard;
  exclude Caladan.
- Reinstall only if the implementation actually requires generated-unit drift.
- Prove an actionable fixture reaches the configured transport once, a routine
  fixture does not, and direct BopBop conversation remains independent.
- Generate Ice Dispatch with its service virtualenv and prove suppressed
  routine activity remains represented.
- Commit and push each repository's scoped config change; do not absorb
  unrelated dirty files.

**Phase gate:** each repo's own gate/doctor plus Shipyard's full battery.

### Phase 4 — Shipyard lifecycle and Codex doctor dogfood (3 pts)

**Delegation:** subagent — reconcile every current ticket against git
reachability and acceptance evidence, propose the complete/pending/freezer map,
then perform only the approved deterministic moves; return ≤40 lines with
filename → class → evidence and doctor/gate results.

- Change `[write_ticket]` to:
  `ticket_dir = "docs/tickets/pending"`,
  `archive_dir = "docs/tickets/complete"`,
  `backlog_dir = "docs/tickets/freezer"`,
  `scan_dirs` covering all three, and `lifecycle_dirs = true`.
- Remove the stale backlog duplicate already authorized by the owner.
- Reconcile ticket status/ledger text to shipped commits before moving files.
- Create/reconcile the root `AGENTS.md` via the installed bridge mechanism;
  do not hand-maintain a divergent skill list.
- Run doctor on Shipyard and verify skill resolution from a real Codex session
  context.

**Phase gate:** ticket lifecycle checker, install/doctor/skill tests,
`install.sh --doctor --project .`, syntax/leak/deck checks, then full Bats.

### Phase 5 — Measurable delegation cutoff and truthful closeout (2 pts)

**Delegation:** subagent — add an exact ISO-8601 `--since` boundary to the
delegation reporter with fixtures, run it at the recorded pipeline cutover,
and return ≤40 lines with sample size, metrics, ledger counts, and blockers.

- `--since` is timezone-aware, inclusive, and mutually coherent with
  `--days`/`--all`; invalid input exits 2 with a useful error.
- Ticket discovery scans lifecycle directories after Phase 4.
- Update `delegation-plan-pipeline.md` with the exact cutoff, current sample,
  and whether its five-session outcome gate is measurable.
- Record the Signal baseline and exact 24-hour follow-up query in this Ledger.
- Graduate this ticket only after every immediately executable acceptance item
  is green. Time-deferred measurements remain explicitly scheduled evidence,
  not fabricated completion claims.

**Phase gate:** delegation-report fixtures and real read-only run, lifecycle
gate, syntax/leak/deck checks, full Bats, doctor, clean status, push.

## Ledger

- 2026-07-28 — Draft created from the owner-requested dogfood pipeline.
- 2026-07-28 — `builder: subagent (1 audit agent)` for investigation:
  123 sends observed; 70 repeated medic classification-failure pages; exact
  control points and notification classification returned in ≤40 lines.
