# Make Shipyard skills discoverable in every installed project

- **Created:** 2026-07-27
- **Owner:** wabbazzar
- **Status:** Draft — local prototype validated; ready for `polish-ticket`
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 5 (3 phases, cap 5/phase)
- **Refs:** `install.sh:120` (`GENERIC_SKILLS`), `install.sh:248-287`
  (`--doctor`), `install.sh:410-459` (`--relink`),
  `install.sh:744-826` (skill installation / bridge),
  `tests/harness-install.bats`, `tests/relink.bats`, `tests/doctor.bats`,
  `README.md` Skills-parity, `docs/INSTALL.md` L5.

## Summary

Shipyard correctly symlinks its seven shared skills into each project's
`.claude/skills/`, but it only writes the Codex/Hermes `AGENTS.md` bridge when
one of the *scheduled* roles is configured with a non-Claude harness. A project
whose crew defaults to Claude therefore has the files but no way for an
interactive Codex or Hermes session to discover them.

Create and repair the bridge for every installed project, regardless of the
scheduled harness. The bridge remains deliberately project-local: do not write
global Codex or Hermes skill directories and do not clobber a project-owned
`AGENTS.md`.

## Problem / Background

The current installer derives `foreign_harness` from `[harness]` / per-role
harness configuration and only then emits the root bridge. That assumption is
wrong: a human can open Codex or Hermes in any installed repository, including
one whose unattended Shipyard roles all use Claude.

The observed failing state is concrete:

1. All seven links in `.claude/skills/` resolve into Shipyard's `skills/`.
2. The project has no root `AGENTS.md` because its scheduled roles use the
   default harness.
3. Codex/Hermes consequently receive no in-repository list telling them to read
   `.claude/skills/<name>/SKILL.md`; `write-ticket`, `execute-ticket`, and the
   other shared workflows are present on disk but not discoverable.

This must not be solved by installing into a user's global Codex or Hermes
home. Those locations are user- and machine-scoped, create cross-project
leakage, and cannot make a repository self-contained. The supported Shipyard
adapter is the root `AGENTS.md` bridge: Codex/Hermes load repository guidance,
then read the same symlinked `SKILL.md` files as Claude.

The host-provided "available skills" menu may still list only host-managed
skills. This ticket guarantees repository discovery and use through
`AGENTS.md`; it must not claim to mutate a host's remote skill catalog.

## Implementation Plan

### Phase 1 — Make bridge generation unconditional (2 points)

**Delegation: subagent — change the installer bridge predicate and return the
focused diff plus targeted bats output.**

- In `install.sh`, replace the `foreign_harness` gate around the skill bridge.
  Every normal install creates the bridge when root `AGENTS.md` is absent,
  including a Claude-only configuration.
- Keep the generated body enumerating every item in `GENERIC_SKILLS` as
  `.claude/skills/<skill>/SKILL.md` and saying to read and follow the named
  skill before acting.
- Preserve the existing ownership boundary: an existing file or symlink at
  `AGENTS.md` is left byte-for-byte unchanged. Do not overwrite, append to, or
  infer ownership of it.
- Extract one small helper if needed so normal install and repair mode share an
  identical generated body.
- Extend `tests/harness-install.bats` with a failing-first regression for a
  fixture with no `[harness]` configuration: normal installation creates the
  bridge and it names `write-ticket` and `execute-ticket`.

### Phase 2 — Detect and repair existing installs without timer side effects (2 points)

**Delegation: subagent — add doctor/relink coverage and return exact drift and
repair output.**

- Add a `--doctor` finding for a missing root bridge, e.g.
  `DOCTOR skill bridge: AGENTS.md missing`. Do not inspect or reject the
  contents of an existing project-owned bridge.
- Expand `--relink` to create only a missing bridge, alongside its existing
  skill-symlink repair. It must not change systemd units, project config,
  gates, or an existing `AGENTS.md`.
- `--relink --dry-run` reports the bridge it would create and writes nothing.
- Extend `tests/doctor.bats` and `tests/relink.bats` with failing-first cases
  for detection, real repair, dry-run non-write, and preservation of an
  existing project-owned file.

### Phase 3 — Align public installer documentation (1 point)

**Delegation: inline (documentation is coupled to the exact verified installer
behavior).**

- Update `README.md`, `docs/INSTALL.md`, and `skills/install/SKILL.md` to say
  that the root bridge is installed for every project, not only for a project
  with a currently non-Claude scheduled role.
- Document the repair path: `install.sh --relink --project <project>` repairs
  the missing bridge without rebaking timers or configuration.
- Keep the scope precise: the bridge gives Codex/Hermes repository-local skill
  discovery; it does not populate a host-managed skill picker.

## Testing Strategy

- `bash -n install.sh`
- Targeted failing-first and green cases in
  `tests/harness-install.bats`, `tests/relink.bats`, and `tests/doctor.bats`.
- `bats tests/`
- `bash scripts/leak-check.sh`
- `bash scripts/check-deck-fresh.sh`

## Definition of Done

- [ ] A Claude-only Shipyard project receives a generated root `AGENTS.md`
      containing every `GENERIC_SKILLS` path.
- [ ] A project with an existing `AGENTS.md` is unchanged.
- [ ] `--doctor` reports a missing bridge and `--relink` restores it without
      systemd or config changes; dry-run creates nothing.
- [ ] The same seven Shipyard skill files remain the source of truth for
      Claude, Codex, and Hermes.
- [ ] Docs explain both the universal bridge and the host-catalog boundary.
- [ ] All listed gates are green.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Overwriting a team's instructions | Treat any existing file or symlink as project-owned and leave it unchanged. |
| Repair mode causes operational side effects | Limit `--relink` to symlinks and a missing bridge; pin with tests. |
| Claiming the hosted Codex skill menu changed | Explicitly document that `AGENTS.md` provides repository discovery, not host catalog registration. |

## Out of scope

- Global installation under Codex or Hermes user homes.
- A Shipyard Codex plugin or marketplace publication.
- Altering the scheduled harness, model, or systemd timers.
