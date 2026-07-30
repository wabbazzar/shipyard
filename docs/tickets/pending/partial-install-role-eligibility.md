# Make partial crew installs safe and observable

- **Created:** 2026-07-30
- **Owner:** wabbazzar
- **Status:** pending — reproduced; draft ready for polish
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

## Implementation Plan

### Phase 1 — Installer and Doctor share a safe role contract (3 pts)

Add red-first coverage for an intentional Scribe-only reinstall, an explicit
missing-prompt request, and Doctor's enabled-role/missing-prompt finding.
Implement the shared eligibility/preflight path before any mutation and keep
systemd/launchd behavior aligned.

Files: `install.sh`, `tests/helpers.bash` or a focused fixture helper,
`tests/doctor.bats`, and the relevant installer/launchd test file.

Proof class: Bats, shell syntax, dry-run output, Doctor, scheduler-shim
non-mutation, and public-repo hygiene.

Delegation: subagent — implement the installer/Doctor slice and return the
red/green test evidence plus exact files changed.

### Phase 2 — Fleet inspection respects partial installs (3 pts)

Add red-first JSON coverage for a project with Scribe enabled and latent
Build/Release/Medic manifests disabled. Preserve all unit inventory fields
while excluding only non-applicable disabled-role fault evidence and attention.

Files: `skills/shipyard/inspect.py`, `tests/shipyard-inspect.bats`.

Proof class: focused inspect Bats, schema-v1 JSON invariants, human-render
bounds, Python compile, and public-repo hygiene.

Delegation: subagent — implement the inspect slice against the locked
eligibility rule and return exact JSON assertions and test counts.

### Phase 3 — Documentation, live proof, and roll-up (2 pts)

Update the canonical installer and operator documentation. Re-run the complete
gate battery, then prove with dry runs and Doctor/inspect on the two intentional
partial installs that no absent role would be enabled and no intentional
disabled role appears as a current fault. Do not enable, remove, or start those
roles during proof.

Files: `README.md`, the existing install reference if its claims require the
same correction, and this ticket's final Ledger/graduation.

Proof class: full Bats, shell/Python syntax, leak firewall, deck freshness and
completeness, lifecycle, read-only live dry runs, Doctor, and JSON inspection.

Delegation: inline (the orchestrator must personally run and read the final
live-system and repository gates).

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
