# Make partial crew installs safe and observable

- **Created:** 2026-07-30
- **Owner:** wabbazzar
- **Status:** pending — polished; no open decisions
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 8 (three phases: 3 · 3 · 2)
- **Refs:** `install.sh:139-205`, `install.sh:396-452`,
  `install.sh:1131-1305`, `skills/shipyard/inspect.py:668-805`,
  `skills/shipyard/inspect.py:4253-4518`, `tests/helpers.bash:225-250`,
  `tests/doctor.bats:38-121`, `tests/shipyard-inspect.bats:588-676`,
  `README.md:235-301`, `.agents/gates.md`

## Summary

Unify role eligibility across the installer, Doctor, and fleet inspection so
an intentional partial crew install remains partial. A default reinstall or
`--wire-shoulder` must not enable roles that the project does not declare,
Doctor must reject an enabled role whose required project prompt is absent,
and `shipyard inspect` must not report intentionally disabled, undeclared role
units as current faults.

## Problem / Background

### Captured reproduction

The live Ice project is intentionally Scribe-only:

```text
build.md   MISSING
release.md MISSING
medic.md   MISSING
scribe.md  present
```

Its documentation and config state that Build, Release, and Medic are
deliberately disabled; each corresponding runner exits `2` without its
project prompt. A second installed project, 2pizzaclub, has the same
intentional partial-install shape.

On 2026-07-30, the Doctor-prescribed shoulder repair was run without an
explicit `--agents` subset:

```bash
./install.sh --project "$ICE_PROJECT" --wire-shoulder
```

The installer wrote canonical Helldiver, Proctor, Suk, and Chronicler jobs,
then ran `enable --now` for all four. Because the timers are persistent, the
three intentionally absent roles started immediately. The live journal
captured:

```text
ice-helldiver.service: project build.md missing; status=2
ice-proctor.service: project release.md not found; status=2
ice-suk.service: project medic.md not found; status=2
```

The same install concluded `install: OK`, and Doctor subsequently reported
`doctor: ice crew install clean` while the selected roles were structurally
unable to run. The three timers were restored to inactive/disabled and their
failed service markers were cleared; Ice Scribe remained active/enabled.

The defect is reproducible without mutating the live scheduler:

1. Confirm only `.agents/scribe.md` exists for the four default scheduled
   roles.
2. Run the installer with `--dry-run --wire-shoulder` and no `--agents`.
3. Observe jobs for all four roles plus
   `would: ... enable --now each timer`.
4. Run `shipyard inspect --json`; observe disabled, undeclared role units
   becoming `observed_fault` attention even though Doctor's eligibility rule
   treats them as non-applicable.

### Violated observable contract

- A reinstall is documented as safe and idempotent; it must not activate a
  runner that is guaranteed to exit `2` on its first required input.
- Doctor must not return clean for an enabled role that cannot load its
  required project prompt.
- Fleet inspection must distinguish an intentionally partial install from a
  disabled expected role, while retaining the latent unit in inventory.

### Root cause and rival causes

| Question | Evidence | Verdict |
|---|---|---|
| Does `[names]` opt every named role into scheduling? | `agents/lib/naming.sh:20-35` maps an already selected canonical role to a display name; selection occurs earlier. | Ruled out. |
| Is this stale scheduler state rather than current installer behavior? | `install.sh:142,195` defaults `ROLES_LIST` to four roles; `install.sh:1139-1150` assigns fallback schedules; `install.sh:1285-1292` enables all selected timers. The live starts share the install timestamp. | Ruled out. |
| Are Ice's missing prompts accidental install drift? | Ice and 2pizzaclub explicitly document Scribe-only installs; the other roles are disabled and known to exit `2` without prompts. | Ruled out. |
| Where is the defect? | Installer role selection ignores the established configured-or-enabled eligibility rule. Doctor checks expected unit presence/enablement/runner location but not required prompt presence. Inspect treats any disabled latent manifest as a current fault. | Ruled in. |

The unsafe default dates to the initial installer extraction (`ce5a130`,
2026-06-05); canonical role/display naming later preserved it in `24a9b8c`.
The same class exists in every intentional partial install, currently Ice and
2pizzaclub.

The coverage gap is specific: `tests/helpers.bash:242-246` always creates all
five project prompts, Doctor has no enabled-role/missing-prompt case, and the
inspect fixture has no intentional partial install with latent disabled units.

### Polishing baseline and live invariants

Measured on 2026-07-30 before any implementation edit:

- `bats tests/` passed `668/668` in the canonical checkout.
- The configured syntax sweep, leak firewall, deck freshness, deck
  completeness, and `./install.sh --doctor --project .` all exited `0`.
- `systemctl --user is-enabled` reported Ice Helldiver, Proctor, and Suk
  `disabled`, and Chronicler `enabled`; `is-active` reported the first three
  `inactive` and Chronicler `active`.
- `bash skills/shipyard/shipyard.sh inspect --json --days 7` retained all four
  Ice units but put six systemd evidence IDs from the three disabled roles in
  `state_reason_ids`.

The execute run must repeat the repository baseline before source edits. It
must snapshot the four Ice timer enabled/active states before each live proof
and show the byte-for-byte same state afterward. The live proof is read-only:
no `daemon-reload`, enable, disable, start, stop, plist load, or plist unload.

## Decisions

| # | Decision | Locked behavior | Why |
|---|---|---|---|
| D-1 | Shared eligibility | With no explicit `--agents`, effective roles are `[install.timers]` keys union currently enabled canonical roles; only when both are empty does the documented four-role default apply. | This matches Doctor's existing lower-bound rule and preserves fresh-install defaults. |
| D-2 | Explicit requests | An explicit `--agents` remains authoritative. Build, Release, Medic, and Scribe selections require their matching `.agents/<role>.md`; missing prompts fail exit `2` before any write or scheduler call. | Explicit requests must fail clearly, never silently skip. |
| D-3 | Design exception | Design remains opt-in and does not require `.agents/design.md`. | Its runner uses the generic role plus gates/config rather than a required project prompt. |
| D-4 | Doctor scope | Doctor checks prompt presence for roles it already considers expected. Disabled, undeclared latent roles remain non-applicable and do not make Doctor red. | Preserve intentional partial installs while detecting runnable-looking broken roles. |
| D-5 | Inspect scope | Disabled, undeclared latent units remain visible in `.fleet[].units` but do not create direct systemd fault evidence, `observed_fault` attention, or a fault project state. | Preserve evidence without presenting intentional absence as breakage. |
| D-6 | No unsafe compatibility switch | This is a fail-closed correction to an existing required-input contract; no config key or opt-out permits activation without a required prompt. | An unsafe runner cannot be a supported legacy behavior. |
| D-7 | Platform parity | Eligibility and preflight happen before scheduler-specific generation, so Linux/systemd and macOS/launchd share the same behavior. | Prevent platform drift. |

There are no open user decisions.

## Technical Requirements

1. Add one canonical role-eligibility calculation in `install.sh` and use it
   for default install selection and Doctor's expected-role audit. Do not use
   `[names]` as eligibility.
2. Validate required project prompts for the effective role set before config
   rewrite, unit/plist writes, stale-unit removal, crontab mutation, skill
   linking, or scheduler calls. Aggregate every missing role in one bounded
   exit-`2` diagnostic.
3. Preserve explicit `--agents` ordering/validation and the fresh-project
   four-role default.
4. Extend Doctor's expected-role loop to emit a prompt-specific finding for
   Build, Release, Medic, or Scribe when the role is expected but its project
   prompt is absent.
5. Pass eligibility into the systemd evidence adapter in
   `skills/shipyard/inspect.py` so latent disabled units are inventory, not
   faults. A failed or inactive enabled/eligible role remains a fault.
6. Add regression fixtures that can omit selected prompt files instead of
   relying only on `make_fixture_project`'s all-prompts shape.
7. Update the existing installer/Doctor/inspect documentation; do not add a
   parallel explainer.

## Implementation Plan and Verification

### Phase 1 — Installer and Doctor share a safe role contract (3 pts)

Add a single role resolver in `install.sh` that runs after config load but
before every write or scheduler operation. Track whether `--agents` was
explicit. Without it, resolve `[install.timers]` keys union enabled canonical
roles, preserving canonical order and using the four-role default only for an
empty union. Use the same resolver in Doctor. Preflight the matching prompt for
Build, Release, Medic, and Scribe and aggregate missing paths before exit `2`;
Design is the only exception.

Files: `install.sh`, `tests/helpers.bash` or a focused fixture helper,
`tests/doctor.bats`, `tests/gap-fixes.bats`, and
`tests/launchd-install.bats`.

Regression names and RED obligation:

- `install: implicit Scribe-only reinstall selects no latent roles`
- `install: explicit required roles with missing prompts fail before mutation`
- `doctor: expected role missing its required prompt is a finding`
- `launchd: implicit partial install uses the same eligible role set`

Before implementation, add the tests and run their exact Bats filters against
the pre-change `install.sh`; record at least one failing TAP assertion showing
the captured defect. Do not weaken an existing full-install or explicit-subset
test. The zero-mutation case snapshots config, manifests/plists, project-owned
files, crontab shim log, and scheduler shim log; the only tolerated output is
the bounded diagnostic naming every missing prompt.

Gate classes: shell scripts, Bats, config-gated additivity, systemd unit
generation, delegation contract, and public-repo hygiene apply. No model,
deck, served-app, event, or notification gate applies. This is a fail-closed
bug correction rather than a new configurable capability, so D-6 forbids a
new opt-out; unchanged fresh/full-install tests are the additive guard.

Run and read:

```bash
bats tests/doctor.bats tests/gap-fixes.bats tests/launchd-install.bats
bash -n install.sh
bash install.sh --dry-run --project "$PARTIAL_FIXTURE"
bash install.sh --doctor --project "$PARTIAL_FIXTURE"
bash scripts/leak-check.sh
```

Observable DoD: focused Bats are green; the implicit Scribe-only dry run names
only Scribe scheduler work; the explicit missing-prompt test exits `2` with no
write/scheduler calls; Doctor exits `1` only when a role in its expected set is
missing a required prompt; all prior full/default/subset cases remain green.

Delegation: subagent — own only `install.sh`, `tests/helpers.bash` if needed,
`tests/doctor.bats`, `tests/gap-fixes.bats`, and
`tests/launchd-install.bats`. Implement D-1 through D-4 and D-7. First capture
the requested RED TAP against pre-change code, then converge to GREEN. Do not
touch live scheduler state, docs, inspect code, or the ticket. Return in at
most 40 lines: files changed; commands plus exit codes; exact RED assertion;
GREEN test counts; zero-mutation evidence; blockers. Converge honestly or
report the precise blocker with the actual evidence — NEVER fake green, weaken
a check, or hand-wave "should work". Run the real command, read the real file,
curl the real port, and report exact output (exit codes, JSONL lines, HTTP
codes), not adjectives.

### Phase 2 — Fleet inspection respects partial installs (3 pts)

Pass raw project config into `_systemd_adapter` in
`skills/shipyard/inspect.py`. Hydrate every discovered unit exactly as today,
derive `[install.timers]` keys union enabled canonical roles with the same
empty-union fallback as Doctor, and gate only fault-ID collection. Never gate
manifest discovery or unit/status serialization.

Files: `skills/shipyard/inspect.py`, `tests/shipyard-inspect.bats`.

Add RED-first case
`inspect: intentional partial install ignores disabled latent role faults`.
Its fixture config declares only Scribe; Scribe is enabled, Build/Release/Medic
manifests remain visible and disabled/inactive, and one latent service may
retain a failed result. Assert all latent unit JSON fields remain present, but
their systemd fault evidence IDs are absent from `state_reason_ids` and from
direct current-fault attention. The existing
`inspect: disabled timer and failed service are direct faults` test must still
prove the empty-union/default eligible role fails.

Gate classes: Python/shell execution, Bats, delegation contract, schema-v1
compatibility, human-render bounds, and public-repo hygiene apply. No live
scheduler mutation, model, deck, served-app, event, or notification gate
applies.

Run and read:

```bash
bats tests/shipyard-inspect.bats
python3 -m py_compile skills/shipyard/inspect.py
bash skills/shipyard/shipyard.sh inspect --json --days 7 | jq -e '.schema_version == 1'
bash skills/shipyard/shipyard.sh inspect --days 7
bash scripts/leak-check.sh
```

Observable DoD: the new case is shown RED before implementation and GREEN
after; all inspect tests pass; schema remains exactly `1`; human output remains
bounded; latent partial-install units remain serialized while only
non-applicable direct systemd fault IDs disappear.

Delegation: subagent — own only `skills/shipyard/inspect.py` and
`tests/shipyard-inspect.bats`. Implement D-5 without changing the schema or
filtering inventory. First capture RED TAP for the named regression, then
converge to GREEN while keeping the existing eligible-disabled fault test.
Return in at most 40 lines: files changed; commands plus exit codes; exact RED
assertion; exact JSON assertions; GREEN test counts; blockers. Converge
honestly or report the precise blocker with the actual evidence — NEVER fake
green, weaken a check, or hand-wave "should work". Run the real command, read
the real file, curl the real port, and report exact output (exit codes, JSONL
lines, HTTP codes), not adjectives.

### Phase 3 — Documentation, live proof, and roll-up (2 pts)

Update the default/partial-install contract in `install.sh` usage comments and
the existing installer/operator sections of `README.md`. Do not add a parallel
document. Re-run every repository gate, then perform read-only live proof on
Ice and 2pizzaclub. Graduate this ticket only after all proof is green.

Files: `install.sh`, `README.md`, and this ticket's Ledger/graduation.

Gate classes: shell/Python syntax, full Bats, systemd dry-run/Doctor,
delegation contract, public-repo hygiene, deck freshness/completeness, ticket
lifecycle, and pushed CI apply. Config additivity remains pinned by the full
suite. No model, served-app, event, or notification gate applies.

Run and read:

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py skills/shipyard/inspect.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
./install.sh --doctor --project .
bash scripts/ticket-lifecycle.sh --project . --check
```

With `ICE_PROJECT` and `PIZZA_PROJECT` pointing to the two canonical checkouts,
snapshot scheduler state, run only dry-run/read-only surfaces, and compare:

```bash
systemctl --user is-enabled ice-helldiver.timer ice-proctor.timer ice-suk.timer ice-chronicler.timer
systemctl --user is-active ice-helldiver.timer ice-proctor.timer ice-suk.timer ice-chronicler.timer
bash install.sh --dry-run --project "$ICE_PROJECT" --wire-shoulder
bash install.sh --doctor --project "$ICE_PROJECT"
bash install.sh --dry-run --project "$PIZZA_PROJECT"
bash install.sh --doctor --project "$PIZZA_PROJECT"
bash skills/shipyard/shipyard.sh inspect --json --days 7 >"$TMPDIR/shipyard-inspect.json"
jq -e '.fleet[] | select(.project_name=="ice") | ([.units[].role] | sort) == ["build","medic","release","scribe"]' "$TMPDIR/shipyard-inspect.json"
systemctl --user is-enabled ice-helldiver.timer ice-proctor.timer ice-suk.timer ice-chronicler.timer
systemctl --user is-active ice-helldiver.timer ice-proctor.timer ice-suk.timer ice-chronicler.timer
```

Read the JSON evidence linkage, not just the project headline: the disabled
latent Ice role systemd evidence IDs must not occur in that project's
`state_reason_ids`; historical job failures may honestly remain in
`attention`. For 2pizzaclub, absent latent manifests are acceptable and Scribe
must remain the only eligible role. Do not claim the whole project healthy
when unrelated/historical evidence says otherwise.

Observable DoD: `668` baseline tests plus all new cases pass; exact syntax,
leak, deck, Doctor, and lifecycle commands exit `0`; both live dry runs plan no
absent role; Ice scheduler snapshots are identical; inspect inventory is
complete and linkage obeys D-5; ticket graduation, commit, push, remote CI, and
GitHub Pages deployment are green. After the commit touching `install.sh`,
`ls -l ~/code/*/.claude/skills/ | grep -c worktrees` must print `0`.

Delegation: inline (a gate command and live-system proof the orchestrator must
personally run and read; this is an allowed delegation exception).

## Testing Strategy

- Add a regression that fails on pre-change code because a default reinstall
  of a configured/enabled Scribe-only fixture attempts scheduler mutation for
  Build, Release, and Medic.
- Add an explicit `--agents build` missing-prompt case that exits `2` before
  config, manifest, or scheduler mutation.
- Add Doctor cases for each required-prompt role with an enabled unit and a
  deleted prompt.
- Add systemd and launchd assertions proving eligibility is scheduler-neutral.
- Add an inspect schema-v1 case proving latent disabled units remain in fleet
  inventory while fault evidence/attention excludes them.
- Keep existing full-install, explicit-subset, disabled-expected-role,
  systemd-failed-service, and human-render tests green.
- Run the configured repository gates: `bats tests/`,
  `bash scripts/leak-check.sh`, and `bash scripts/check-deck-fresh.sh`.

## Orchestration Protocol

The builder is the orchestrator: keep its context lean, delegate Phases 1 and
2 using the briefs above, and personally re-read every changed hunk and rerun
each phase's exact gates before committing. Each phase is one clean commit.
Before delegation, append the plan and `builder:` line to the Ledger; after
verification, append the commit and measured evidence. Never trust a
subagent's summary as proof.

Shipyard runs directly on `main`; do not create a worktree or branch. Check
`git status --short --branch` before every commit, explicitly stage only the
phase-owned files, and preserve unrelated user work. `install.sh` is
fleet-live at the next project install, so no phase may leave default
selection unsafe or tests red. Do not push until all phases and final gates
are complete.

## Acceptance Criteria / Definition of Done

- [ ] The captured partial-install repro no longer plans or performs activation
      of undeclared Build, Release, or Medic roles.
- [ ] Explicit selection of a required-prompt role with no project prompt exits
      `2` before any write or scheduler mutation and names every missing prompt.
- [ ] Fresh projects with no declared/enabled role set retain the documented
      Build/Release/Medic/Scribe default.
- [ ] Doctor exits `1` for an expected enabled role whose required prompt is
      absent, and remains clean for disabled undeclared latent roles.
- [ ] `shipyard inspect --json` retains latent units in inventory without
      turning intentional partial installs into current fault attention.
- [ ] Linux and macOS scheduler tests pin the same eligibility behavior.
- [ ] Ice and 2pizzaclub are verified read-only: Scribe remains enabled, absent
      roles remain disabled/absent, and no test starts them.
- [ ] Full repository gates pass, the ticket is graduated only after completion,
      the Shipyard worktree is clean, and pushed CI is green.

## Ledger

Append before and after each phase. Required shape:

### Phase 1 — Installer and Doctor share a safe role contract

builder: subagent (1 agent)

plan: Own `install.sh` and the focused installer/Doctor/launchd tests; capture
the pre-change RED for partial-role activation, implement D-1 through D-4 and
D-7, and return focused evidence for orchestrator re-verification.

commit: Phase 1 commit (hash recorded in the Phase 2 Ledger entry).

evidence: Execute baseline before source edits passed `668/668`; configured
syntax, Python compile, leak, deck freshness/completeness, and Shipyard Doctor
all exited `0`. RED-first cases proved the old installer created and enabled
all four roles for implicit systemd and launchd partial installs; explicit
missing prompts returned `0` and mutated files; Doctor returned clean. After
implementation, the orchestrator ran
`bats tests/doctor.bats tests/gap-fixes.bats tests/launchd-install.bats`:
`61/61` passed. `bash -n install.sh`, `git diff --check`, and leak check exited
`0`. The explicit failure case snapshots project/manifests and proves zero
`systemctl` and `crontab` calls. Ice timer state remained
`disabled/disabled/disabled/enabled` and
`inactive/inactive/inactive/active`.

deferred: none

```text
### Phase N — <title>
builder: subagent (1 agent) | inline (<allowed reason>)
plan: <owned files and proof>
commit: <hash, after verification>
evidence: <commands, exact exits/counts, live invariant>
deferred: none | <honest remainder>
```

Run with `execute-ticket` after polish. The ticket has no open decision, so the
pipeline auto-gate proceeds without another approval.

## Dependencies

None.

## Risks & Mitigations

- **Risk:** changing implicit role selection breaks a legitimate full install.
  **Mitigation:** preserve the four-role fallback only when no configured or
  enabled role evidence exists, and pin fresh/full fixtures.
- **Risk:** a renamed display unit is missed. **Mitigation:** derive enabled
  canonical roles through the existing manifest/runner matching functions,
  never filename guesses or `[names]`.
- **Risk:** inspect hides a truly disabled expected timer. **Mitigation:** only
  suppress direct faults for roles outside the locked eligibility set; retain
  current disabled-expected and failed-enabled tests.
- **Risk:** validation writes part of an install before failing. **Mitigation:**
  assert zero filesystem/scheduler mutation and place validation before every
  installer write surface.

## Out of Scope

- Creating Build, Release, Medic, or Design prompt files for partial projects.
- Enabling, starting, removing, or renaming any Ice or 2pizzaclub role.
- Deleting latent disabled scheduler manifests.
- Changing `[names]` semantics or editing project `[install.timers]`.
- Reclassifying historical `job.end status=fail` evidence.
- Remediating the stale MG scratchpad install.
- Changing shoulder delivery behavior beyond making its installer invocation
  respect the same role eligibility contract.
