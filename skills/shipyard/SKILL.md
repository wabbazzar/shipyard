---
name: shipyard
roles: [human]
disposition: new
kind: frontdoor
description: >
  Inspect and extend an installed crew from inside a project. Triggers on
  "/shipyard", "/shipyard status", "shipyard status", "what crew is installed
  here", "add a specialist for <subsystem>", or "shipyard learn <lesson>". Three
  subcommands: `status` (read-only report of the units/timers installed here,
  where each `.agents/<role>.md` project block lives, and an install.sh --doctor
  drift audit), `add-specialist <subsystem>` (scaffold the domain-specialist
  archetype for one subsystem and wire it into gates/critic/write_ticket), and
  `learn "<lesson>"` (route a lesson through the ADAPTING.md triage taxonomy to
  a project note or a core-change stub). The deterministic core is
  `skills/shipyard/shipyard.sh` — run it; do not reimplement its logic in prose.
---

# shipyard — inspect and extend an installed crew

The crew is hub-and-spoke: the runners, skills, and installer live in the
harness repo, and a project opts in by installing units + symlinking the shared
skills. `/shipyard` is the **operator's in-project console** for that install —
"what's wired here, and how do I grow it" — without hand-editing units, gates,
or critic blocks.

**The behavior lives in `shipyard.sh`, not in this file.** This skill's job is
to pick the subcommand and run the script, then read its output back to the
operator. The script owns the load-bearing exit codes (`0` ok, `2` bad
invocation/config, `3` nothing installed) so the behavior is testable and
identical whether a human or an agent invokes it.

## Usage

Run the core from the project you're asking about (its symlinked copy is at
`.claude/skills/shipyard/shipyard.sh`; in the harness repo it's
`skills/shipyard/shipyard.sh`):

```bash
bash .claude/skills/shipyard/shipyard.sh status
bash .claude/skills/shipyard/shipyard.sh add-specialist <subsystem>
bash .claude/skills/shipyard/shipyard.sh learn "<lesson>"
```

Pass `--project <dir>` to target a different checkout than the current one.

## Subcommands

### `status` (default)

Read-only. Enumerates the systemd user timers installed for this project, lists
where each role's `.agents/<role>.md` project block lives, and — when the full
toolchain is present — runs `install.sh --doctor` for a drift audit. Exits `3`
when nothing is installed here (a deliberate no-op the caller can branch on),
`0` otherwise. Never writes anything.

### `add-specialist <subsystem>`

Scaffolds the domain-specialist archetype (`agents/specialist/`) for one named
subsystem and wires it into the project. Missing subsystem name ⇒ exit `2`. See
the specialist archetype in `docs/ADAPTING.md`.

### `learn "<lesson>"`

Routes a lesson through the `docs/ADAPTING.md` triage taxonomy
(project-specific / generic / install-time) to the right destination. Empty or
ambiguous lesson ⇒ exit `2`.

## Reading the result

Relay the script's output faithfully — the timer list, the block locations, the
doctor findings. On exit `3`, tell the operator nothing is installed here and
offer `install.sh --project <dir>`. On exit `2`, surface exactly what was
malformed; do not paper over it.
