---
name: shipyard
roles: [human]
disposition: new
kind: frontdoor
description: >
  Inspect and extend an installed crew from inside a project. Triggers on
  "/shipyard", "/shipyard status", "shipyard status", "what crew is installed
  here", "/shipyard inspect", "shipyard inspect", "fleet health", "where should
  the next Shipyard PR focus", "add a specialist for <subsystem>", or "shipyard
  learn <lesson>". Four subcommands: `status` (read-only report of the local
  install), `inspect` (strictly read-only current-user fleet evidence, rendered
  for humans by default or as stable schema-v1 JSON), `add-specialist
  <subsystem>` (scaffold and wire a domain specialist), and `learn "<lesson>"`
  (route a lesson through the ADAPTING.md taxonomy). The deterministic core is
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

Run the core from the project you're asking about. Codex discovers
`.agents/skills/shipyard`; Claude and Hermes discover
`.claude/skills/shipyard`; both symlinks resolve to the same
`skills/shipyard/` core:

```bash
bash .claude/skills/shipyard/shipyard.sh status
bash .claude/skills/shipyard/shipyard.sh inspect [--json] [--days N]
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

### `inspect`

Strictly read-only across matching current-user manifests into this Shipyard core.
It accepts only canonical service manifests whose runner resolves into the
current core and whose project and working-directory operands agree. It never
starts or changes a unit, calls a model or network, sends a notification,
records a decision, creates a ticket, or changes a repository.

The default is a human operator view; `--json` emits stable schema-v1 JSON from
the same document, and `--days N` selects the bounded evidence window. The
report does not certify fleet health: missing, malformed, stale, or
non-atomically-read sources remain explicit coverage and limitations.
Recommendations for the next Shipyard PR are deterministic, bounded by evidence and reported limitations.
Direct core evidence may support a Shipyard-core fact; cross-project recurrence
and model-authored proposals remain assessments. A design/shoulder budget scope
is shared only when the current inspection proves the same resolved gate root
for multiple eligible projects; an unknown shoulder root is never inferred.

### `add-specialist <subsystem>`

Scaffolds the domain-specialist archetype (`agents/specialist/`) for one named
subsystem and wires it into the project. Missing subsystem name ⇒ exit `2`. See
the specialist archetype in `docs/ADAPTING.md`.

### `learn "<lesson>"`

Routes a lesson through the `docs/ADAPTING.md` triage taxonomy
(project-specific / generic / install-time) to the right destination. Empty or
ambiguous lesson ⇒ exit `2`.

## Reading the result

Relay the script's output faithfully. For `inspect`, do not collapse
`partial`/`unavailable` into green or present an assessment as a proven core
fault. On exit `3`, tell the operator nothing matching is installed. On exit
`2`, surface exactly what was malformed; do not paper over it.
