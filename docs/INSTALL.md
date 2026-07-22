# Installing the crew — the six-layer model

A harness ships in layers: a generic core at the bottom, operator taste at the
top. **Installing is writing the top layers; upgrading is pulling the bottom
one.** Every layer is inspectable and revertable, and the repo keeps nothing it
didn't choose.

The `install` skill (`skills/install/SKILL.md`) drives the human-facing flow;
`install.sh` does the mechanical writes. This document is the model they both
implement.

## The layers

### L0 — core
**Where:** the harness repo, shared by every project.
**What:** runners, the shared lib, the skills, the installer — generic, with
zero personal facts (enforced by `scripts/leak-check.sh` in CI). **Units execute
runners from the clone, so a merge to trunk is fleet-live at the next timer
fire.** This is the only layer an upgrade touches; every project inherits it.

### L1 — hub knobs
**Where:** baked into the systemd units at install time (env in the unit file).
**What:** where events, notifications, and dashboard state flow:

```
QUARTET_NOTIFY_CMD   # the single owner-alert path (a notify wrapper)
QUARTET_OPS_JSON     # dashboard ops-state file (optional)
QUARTET_EVENTS_DIR   # append-only JSONL event stream directory
```

Units **bake** env; they don't read it live. Changing a knob means re-running
the installer. A user-instance systemd service starts with a near-empty
environment, so an unbaked knob silently mutes notifications and disables the
ops scan — the installer propagates each set knob into every unit it writes.

### L2 — theme
**Where:** `--theme` flag → `[names]` block in `.agents/config.toml`.
**What:** display names for units, svc strings, and notification voice:
`plain` (role IDs verbatim: design/build/release/medic/scribe), `spacetime`
(five themed names), or `custom:d,b,r,m,s` (five names in role order). **Role
IDs underneath never change** — they drive the agent dir, the config section,
and the event `role:` field. A legacy install with no `[names]` block keeps its
exact unit names until re-baked with a theme (the safety property: merging a
rename must not rename the running fleet).

### L3 — project config
**Where:** `.agents/config.toml`.
**What:** the gates and budgets: `can_merge` (default **no**), `allow_no_ci`
(default **no**), trunk branch, token caps (1M/day per agent — all caps are
token-based, never dollars), `test_cmd` / `typecheck`, paths. Plus the gate
file `.agents/gates.md` (test/build/lint commands, which gate classes apply,
the Traps appendix) that polish-ticket and execute-ticket read.

### L4 — roles + conventions
**Where:** `.agents/<role>.md`.
**What:** project-specific prompt extensions per crew role, and — on
`release.md` — the **`## Conventions`** block: the operator's stated taste (LOC
economy, dependency policy, naming, comment density) that the release critic
grades against. Asked for at install time; never inferred.

### L5 — skills
**Where:** `<project>/.claude/skills/` (symlinks into `<harness>/skills/`).
**What:** `polish-ticket`, `execute-ticket`, `coverage-audit` — **the same
files agents load headless and humans invoke in-session.** One implementation,
two callers, no agent-only fork. The installer symlinks the harness skills so a
core upgrade (L0) flows to every project's skills at once.

## The flow

```
recon  →  interview  →  write L2–L5  →  bake units  →  verify
```

1. **Recon first.** `coverage-audit` reads the project's session history
   (bugs the operator reported that tests missed) before anything is
   configured — those failure classes tune the release rubric and build.
   Plus a shell sweep: stack (Python vs Node), git remote + `gh auth`,
   tracked-secrets sweep, medic service surface, chat-DB shape, checked-in
   subagents.
2. **Interview.** Theme, gates, service surface, conventions, the merge/data
   forks — bring a concrete proposal, confirm only what can't be inferred.
3. **Write L2–L5.** Author `.agents/config.toml` + per-role blocks; drop
   `gates.md` (installer, from the template — never clobbering an existing
   one) and fill it in; the theme block; the conventions block.
4. **Bake units.** `install.sh --project <dir> --theme <t>` writes the systemd
   units with L1 env baked in, symlinks the L5 skills, enables the timers,
   removes legacy cron launchers.
5. **Verify.** `medic --mode scan --dry-run` loads clean, the release gates
   are green now, `list-timers` shows sane next-fires, the three skill
   symlinks resolve.

## Uninstall

Remove the units and delete `.agents/`:

```bash
systemctl --user disable --now <project>-*.timer
rm ~/.config/systemd/user/<project>-*.{service,timer}
systemctl --user daemon-reload
rm -rf <project>/.agents <project>/.claude/skills/{polish-ticket,execute-ticket,coverage-audit}
```

The repo keeps nothing it didn't choose — the crew leaves no code behind, only
the config the operator wrote and can read.
